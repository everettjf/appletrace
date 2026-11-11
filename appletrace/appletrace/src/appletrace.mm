//
//  appletrace.mm
//  appletrace
//

#import "appletrace.h"

#import <objc/runtime.h>

#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>

namespace {

constexpr size_t kDefaultBlockSize = 16 * 1024 * 1024;
constexpr size_t kMinimumBlockSize = 1 * 1024 * 1024;
constexpr size_t kMaximumBlockSize = 256 * 1024 * 1024;

// Per-thread accumulation buffer tunables (see docs/perf-batching-design.md).
constexpr size_t kBatchFlushThresholdBytes = 32 * 1024;
constexpr size_t kBatchReserveBytes = 64 * 1024;

// Background drain cadence. Bounds how much data a killed process can lose.
constexpr uint64_t kDefaultFlushIntervalMs = 1000;
constexpr uint64_t kMaximumFlushIntervalMs = 60 * 60 * 1000;

// Binary mode: per-thread pointer -> id cache size before it is reset. Keeps a
// caller that passes a fresh buffer for every event from growing it forever.
constexpr size_t kMaximumPointerCacheEntries = 4096;

NSString *EnvironmentValue(NSString *key) {
    return [[[NSProcessInfo processInfo] environment] objectForKey:key];
}

bool BoolFromEnvironment(NSString *key, bool fallback) {
    NSString *value = EnvironmentValue(key);
    if (!value.length) {
        return fallback;
    }

    NSString *normalized = [value.lowercaseString
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([normalized isEqualToString:@"0"] || [normalized isEqualToString:@"false"] ||
        [normalized isEqualToString:@"no"] || [normalized isEqualToString:@"off"]) {
        return false;
    }
    if ([normalized isEqualToString:@"1"] || [normalized isEqualToString:@"true"] ||
        [normalized isEqualToString:@"yes"] || [normalized isEqualToString:@"on"]) {
        return true;
    }
    NSLog(@"AppleTrace: ignoring malformed %@=%@ (expected 1/0, true/false, yes/no)", key, value);
    return fallback;
}

// Parses a non-negative decimal integer. Returns `fallback` for anything else
// (empty, negative, trailing garbage, overflow) so a typo never changes
// behavior silently.
uint64_t UnsignedFromEnvironment(NSString *key, uint64_t fallback) {
    NSString *value = EnvironmentValue(key);
    if (!value.length) {
        return fallback;
    }
    const char *text = value.UTF8String;
    if (!text || *text < '0' || *text > '9') {
        NSLog(@"AppleTrace: ignoring malformed %@=%@", key, value);
        return fallback;
    }
    char *end = nullptr;
    errno = 0;
    unsigned long long parsed = strtoull(text, &end, 10);
    if (errno != 0 || !end || *end != '\0') {
        NSLog(@"AppleTrace: ignoring malformed %@=%@", key, value);
        return fallback;
    }
    return static_cast<uint64_t>(parsed);
}

size_t BlockSizeFromEnvironment() {
    uint64_t megabytes = UnsignedFromEnvironment(@"APPLETRACE_BLOCK_SIZE_MB", 0);
    if (megabytes == 0) {
        return kDefaultBlockSize;
    }
    if (megabytes > kMaximumBlockSize / (1024 * 1024)) {
        return kMaximumBlockSize;
    }

    size_t bytes = static_cast<size_t>(megabytes) * 1024 * 1024;
    if (bytes < kMinimumBlockSize) {
        return kMinimumBlockSize;
    }
    return bytes;
}

// Binary is the default output format: no string formatting on the hot path
// and roughly half the size of JSON lines. APPLETRACE_FORMAT=text (or the
// legacy APPLETRACE_BINARY=0) selects human-readable JSON lines.
bool BinaryFormatFromEnvironment() {
    NSString *format = EnvironmentValue(@"APPLETRACE_FORMAT").lowercaseString;
    if ([format isEqualToString:@"text"] || [format isEqualToString:@"json"]) {
        return false;
    }
    if ([format isEqualToString:@"binary"]) {
        return true;
    }
    if (format.length) {
        NSLog(@"AppleTrace: ignoring malformed APPLETRACE_FORMAT=%@ (expected binary or text)", format);
    }
    return BoolFromEnvironment(@"APPLETRACE_BINARY", true);
}

// Appends `input` as the body of a JSON string. Writes straight into `out`
// (whose capacity is reserved up front), so it does not allocate.
void AppendJSONEscaped(std::string &out, const char *input) {
    if (!input) {
        return;
    }
    static const char kHex[] = "0123456789abcdef";
    for (const unsigned char *cursor = reinterpret_cast<const unsigned char *>(input); *cursor; ++cursor) {
        const unsigned char c = *cursor;
        switch (c) {
            case '\\': out.append("\\\\", 2); break;
            case '"': out.append("\\\"", 2); break;
            case '\b': out.append("\\b", 2); break;
            case '\f': out.append("\\f", 2); break;
            case '\n': out.append("\\n", 2); break;
            case '\r': out.append("\\r", 2); break;
            case '\t': out.append("\\t", 2); break;
            default:
                if (c < 0x20) {
                    const char escaped[6] = {'\\', 'u', '0', '0', kHex[c >> 4], kHex[c & 0xF]};
                    out.append(escaped, sizeof(escaped));
                } else {
                    out.push_back(static_cast<char>(c));
                }
                break;
        }
    }
}

void AppendDecimal(std::string &out, uint64_t value) {
    char buffer[24];
    char *end = buffer + sizeof(buffer);
    char *cursor = end;
    do {
        *--cursor = static_cast<char>('0' + value % 10);
        value /= 10;
    } while (value != 0);
    out.append(cursor, static_cast<size_t>(end - cursor));
}

void AppendLiteral(std::string &out, const char *literal) {
    out.append(literal, strlen(literal));
}

}  // namespace

namespace appletrace {

// Binary fragment format (see docs/binary-fragment-format.md). Apple targets are
// little-endian, so native integers are appended as-is.
constexpr char kBinaryMagic[8] = {'A', 'P', 'L', 'T', 'R', 'C', '0', '1'};
constexpr uint8_t kBinaryTagString = 0x01;

static inline void AppendByte(std::string &buffer, uint8_t value) {
    buffer.push_back(static_cast<char>(value));
}

static inline void AppendU32(std::string &buffer, uint32_t value) {
    buffer.append(reinterpret_cast<const char *>(&value), sizeof(value));
}

static inline void AppendU64(std::string &buffer, uint64_t value) {
    buffer.append(reinterpret_cast<const char *>(&value), sizeof(value));
}

class Logger {
public:
    explicit Logger(size_t block_size) : block_size_(block_size) {}
    ~Logger() { Close(); }

    bool Open(const char *log_path) {
        Close();

        ::remove(log_path);
        fd_ = ::open(log_path, O_CREAT | O_RDWR, static_cast<mode_t>(0600));
        if (fd_ < 0) {
            NSLog(@"AppleTrace: failed to open log file %s", log_path);
            return false;
        }

        if (::ftruncate(fd_, static_cast<off_t>(block_size_)) != 0) {
            NSLog(@"AppleTrace: failed to size log file %s", log_path);
            Close();
            return false;
        }

        file_start_ = static_cast<char *>(::mmap(nullptr, block_size_, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0));
        if (file_start_ == MAP_FAILED) {
            file_start_ = nullptr;
            NSLog(@"AppleTrace: failed to map log file %s", log_path);
            Close();
            return false;
        }

        file_cur_ = file_start_;
        cur_size_ = 0;
        return true;
    }

    // Unmaps the fragment and truncates it to the bytes actually written.
    void Close() {
        Flush();

        if (file_start_) {
            ::munmap(file_start_, block_size_);
        }
        if (fd_ >= 0) {
            ::ftruncate(fd_, static_cast<off_t>(cur_size_));
            ::close(fd_);
        }

        fd_ = -1;
        file_start_ = nullptr;
        file_cur_ = nullptr;
        cur_size_ = 0;
    }

    void Flush() {
        if (!file_start_ || fd_ < 0) {
            return;
        }
        if (cur_size_ > 0) {
            ::msync(file_start_, cur_size_, MS_SYNC);
        }
        ::fsync(fd_);
    }

    // Appends `size` bytes plus a trailing newline.
    bool AddLine(const char *data, size_t size) {
        if (!file_cur_) {
            return false;
        }

        const size_t required = size + 1;
        if (cur_size_ + required > block_size_) {
            return false;
        }

        memcpy(file_cur_, data, size);
        file_cur_ += size;
        *file_cur_++ = '\n';
        cur_size_ += required;
        return true;
    }

    // Appends raw bytes verbatim (no newline). Used by the binary fragment path.
    bool AddRaw(const char *data, size_t size) {
        if (!file_cur_) {
            return false;
        }
        if (cur_size_ + size > block_size_) {
            return false;
        }
        memcpy(file_cur_, data, size);
        file_cur_ += size;
        cur_size_ += size;
        return true;
    }

private:
    size_t block_size_;
    int fd_ = -1;
    char *file_start_ = nullptr;
    char *file_cur_ = nullptr;
    size_t cur_size_ = 0;
};

class LoggerManager {
public:
    LoggerManager() : log_(BlockSizeFromEnvironment()) {}

    void EnableBinary(uint32_t pid) {
        binary_ = true;
        header_pid_ = pid;
    }

    bool Open() {
        if (closed_) {
            return false;
        }
        std::string path = GetFilePath();
        if (path.empty() || !log_.Open(path.c_str())) {
            return false;
        }
        ++file_counter_;
        if (binary_) {
            WriteBinaryHeader();
        }
        return true;
    }

    void Flush() {
        log_.Flush();
    }

    // Final close (process exit): truncates the fragment to its real size and
    // refuses to roll over into a new fragment afterwards.
    void Close() {
        closed_ = true;
        log_.Close();
    }

    void AddLine(const char *data, size_t size) {
        if (log_.AddLine(data, size)) {
            return;
        }
        if (closed_) {
            return;
        }

        NSLog(@"AppleTrace: rolling trace fragment");
        if (!Open()) {
            return;
        }

        if (!log_.AddLine(data, size)) {
            NSLog(@"AppleTrace: failed to write event after rollover");
        }
    }

    // Writes a batch of events. In text mode it splits on '\n' and reuses
    // AddLine so fragment rollover stays on line boundaries; in binary mode it
    // writes the batch verbatim, rolling over whole-batch so a record is never
    // split across fragments (batches always end on a record boundary).
    void AddBlock(const std::string &block) {
        if (binary_) {
            AddRawBlock(block);
            return;
        }

        const char *base = block.data();
        size_t start = 0;
        const size_t size = block.size();
        while (start < size) {
            const void *found = memchr(base + start, '\n', size - start);
            size_t end = found ? static_cast<size_t>(static_cast<const char *>(found) - base) : size;
            if (end > start) {
                AddLine(base + start, end - start);
            }
            if (!found) {
                break;
            }
            start = end + 1;
        }
    }

    static NSString *CurrentDirectory() {
        InitializeWorkDirectory();
        return work_dir_;
    }

private:
    void WriteBinaryHeader() {
        std::string header(kBinaryMagic, sizeof(kBinaryMagic));
        AppendU32(header, header_pid_);
        log_.AddRaw(header.data(), header.size());
    }

    void AddRawBlock(const std::string &block) {
        if (block.empty()) {
            return;
        }
        if (log_.AddRaw(block.data(), block.size())) {
            return;
        }
        if (closed_) {
            return;
        }

        NSLog(@"AppleTrace: rolling trace fragment");
        if (!Open()) {
            return;
        }
        if (!log_.AddRaw(block.data(), block.size())) {
            NSLog(@"AppleTrace: failed to write binary batch after rollover");
        }
    }

    static void InitializeWorkDirectory() {
        static dispatch_once_t once_token;
        dispatch_once(&once_token, ^{
            NSString *configured = EnvironmentValue(@"APPLETRACE_DATA_DIR");
            NSString *root_dir = configured.length
                                     ? configured.stringByExpandingTildeInPath.stringByStandardizingPath
                                     : [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject
                                           stringByAppendingPathComponent:@"appletracedata"];
            if (!root_dir.length) {
                root_dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"appletracedata"];
            }

            NSFileManager *file_manager = [NSFileManager defaultManager];
            BOOL keep_existing = BoolFromEnvironment(@"APPLETRACE_KEEP_EXISTING", false);
            work_dir_ = root_dir;

            if (keep_existing) {
                NSInteger sequence = 1;
                while ([file_manager fileExistsAtPath:work_dir_]) {
                    NSString *name = [NSString stringWithFormat:@"%@_%ld", root_dir.lastPathComponent, (long)sequence];
                    work_dir_ = [root_dir.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
                    sequence += 1;
                }
            } else {
                [file_manager removeItemAtPath:work_dir_ error:nil];
            }

            NSError *error = nil;
            [file_manager createDirectoryAtPath:work_dir_ withIntermediateDirectories:YES attributes:nil error:&error];
            if (error) {
                NSLog(@"AppleTrace: failed to create trace directory %@: %@", work_dir_, error);
            }
        });
    }

    std::string GetFilePath() {
        InitializeWorkDirectory();
        if (!work_dir_.length) {
            return std::string();
        }

        int file_index = file_counter_.load();
        NSString *extension = binary_ ? @"appletracebin" : @"appletrace";
        NSString *log_name = file_index == 0
                                 ? [NSString stringWithFormat:@"trace.%@", extension]
                                 : [NSString stringWithFormat:@"trace_%d.%@", file_index, extension];
        NSString *log_path = [work_dir_ stringByAppendingPathComponent:log_name];
        NSLog(@"AppleTrace: log path = %@", log_path);
        return std::string(log_path.UTF8String);
    }

    static std::atomic<int> file_counter_;
    static NSString *work_dir_;
    Logger log_;
    bool binary_ = false;
    bool closed_ = false;
    uint32_t header_pid_ = 0;
};

std::atomic<int> LoggerManager::file_counter_{0};
NSString *LoggerManager::work_dir_ = nil;

class Trace;

struct PointerNameEntry {
    uint32_t id;
    std::string name;
};

// Per-thread accumulation buffer. The hot path appends under `lock`; the
// background drain, APTFlush and thread exit drain it. See
// docs/perf-batching-design.md.
struct ThreadLog {
    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    std::string pending;
    // Binary mode only: this thread's name -> globally-unique id map. Each
    // thread emits its own string definitions, so a thread only ever references
    // ids it defined — no cross-thread ordering hazard with batched flushing.
    std::unordered_map<std::string, uint32_t> name_ids;
    // Hot-path cache keyed by the caller's pointer (interned objc_msgSend names,
    // Swift StaticStrings and C literals are stable). Every hit is verified with
    // strcmp, so a reused buffer holding a different name falls back safely.
    std::unordered_map<const char *, PointerNameEntry> pointer_ids;
};

static pthread_key_t gThreadLogKey;
static pthread_once_t gThreadLogKeyOnce = PTHREAD_ONCE_INIT;
static Trace *gActiveTrace = nullptr;
static std::atomic<uint32_t> gBinaryNextNameId{0};
static std::atomic<uint64_t> gNextAsyncId{1};

static void appletrace_thread_log_destructor(void *pointer);

static void appletrace_make_thread_log_key() {
    pthread_key_create(&gThreadLogKey, appletrace_thread_log_destructor);
}

class Trace {
public:
    bool Open() {
        static dispatch_once_t once_token;
        dispatch_once(&once_token, ^{
            enabled_.store(BoolFromEnvironment(@"APPLETRACE_ENABLED", true));
            binary_ = BinaryFormatFromEnvironment();
            pid_ = getpid();
            gActiveTrace = this;

            if (binary_) {
                log_.EnableBinary(static_cast<uint32_t>(pid_));
            }
            if (!log_.Open()) {
                return;
            }

            mach_timebase_info(&timeinfo_);
            begin_ = CurrentTimeNs();
            queue_ = dispatch_queue_create("appletrace.queue", DISPATCH_QUEUE_SERIAL);

            const char *process_name = [[NSProcessInfo processInfo] processName].UTF8String;
            if (binary_) {
                EmitMetadata("process_name", 0, process_name);
            } else {
                std::string line;
                AppendLiteral(line, "{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":");
                AppendDecimal(line, static_cast<uint64_t>(pid_));
                AppendLiteral(line, ",\"tid\":0,\"args\":{\"name\":\"");
                AppendJSONEscaped(line, process_name);
                AppendLiteral(line, "\"}}");
                dispatch_sync(queue_, ^{
                    log_.AddLine(line.data(), line.size());
                    log_.Flush();
                });
            }

            StartBackgroundDrain();
        });

        return queue_ != nullptr;
    }

    void SetEnabled(bool enabled) {
        enabled_.store(enabled);
    }

    bool IsEnabled() const {
        return enabled_.load(std::memory_order_relaxed);
    }

    const char *GetTraceDirectory() const {
        return LoggerManager::CurrentDirectory().UTF8String;
    }

    void WriteSection(const char *name, char phase) {
        if (!Ready(name)) {
            return;
        }

        const uint64_t thread_id = ResolveThreadId();
        const uint64_t elapsed_us = ElapsedMicros();
        if (binary_) {
            EmitBinaryEvent(phase, name, thread_id, elapsed_us, 0);
            return;
        }
        EmitText([&](std::string &out) {
            AppendEventPrefix(out, name, phase);
            AppendEventSuffix(out, thread_id, elapsed_us);
            out.push_back('}');
        });
    }

    void WriteInstant(const char *name) {
        if (!Ready(name)) {
            return;
        }

        const uint64_t thread_id = ResolveThreadId();
        const uint64_t elapsed_us = ElapsedMicros();
        if (binary_) {
            EmitBinaryEvent('i', name, thread_id, elapsed_us, 0);
            return;
        }
        EmitText([&](std::string &out) {
            AppendEventPrefix(out, name, 'i');
            AppendEventSuffix(out, thread_id, elapsed_us);
            AppendLiteral(out, ",\"s\":\"t\"}");
        });
    }

    void WriteCounter(const char *name, double value) {
        if (!Ready(name)) {
            return;
        }

        const uint64_t thread_id = ResolveThreadId();
        const uint64_t elapsed_us = ElapsedMicros();
        if (binary_) {
            uint64_t bits = 0;
            memcpy(&bits, &value, sizeof(bits));
            EmitBinaryEvent('C', name, thread_id, elapsed_us, bits);
            return;
        }
        char value_buffer[64] = {0};
        if (std::isnan(value) || std::isinf(value)) {
            snprintf(value_buffer, sizeof(value_buffer), "0");  // JSON has no NaN/Inf
        } else {
            snprintf(value_buffer, sizeof(value_buffer), "%.17g", value);
        }
        EmitText([&](std::string &out) {
            AppendEventPrefix(out, name, 'C');
            AppendEventSuffix(out, thread_id, elapsed_us);
            AppendLiteral(out, ",\"args\":{\"value\":");
            AppendLiteral(out, value_buffer);
            AppendLiteral(out, "}}");
        });
    }

    // Nestable async events ("b"/"e"): used to track work that flows across
    // threads or dispatch queues, matched by (name, async_id).
    void WriteAsync(const char *name, char phase, uint64_t async_id) {
        if (!Ready(name)) {
            return;
        }

        const uint64_t thread_id = ResolveThreadId();
        const uint64_t elapsed_us = ElapsedMicros();
        if (binary_) {
            EmitBinaryEvent(phase, name, thread_id, elapsed_us, async_id);
            return;
        }
        EmitText([&](std::string &out) {
            AppendEventPrefix(out, name, phase);
            AppendLiteral(out, ",\"id\":");
            AppendDecimal(out, async_id);
            AppendEventSuffix(out, thread_id, elapsed_us);
            out.push_back('}');
        });
    }

    // Async begin annotated with the Swift task that started it. Text mode
    // adds `"args":{"task":...}`; binary mode writes a 'T' record (name = task
    // name, arg = async id) immediately before the 'b' record, under the same
    // lock so both land in one batch.
    void WriteAsyncBeginWithTask(const char *name, uint64_t async_id, const char *task) {
        if (!task || !*task) {
            WriteAsync(name, 'b', async_id);
            return;
        }
        if (!Ready(name)) {
            return;
        }

        const uint64_t thread_id = ResolveThreadId();
        const uint64_t elapsed_us = ElapsedMicros();
        if (binary_) {
            if (!IsEnabled() || !queue_) {
                return;
            }
            ThreadLog *thread_log = AcquireThreadLog();
            os_unfair_lock_lock(&thread_log->lock);
            uint32_t task_id = BinaryNameIdLocked(thread_log, task);
            uint32_t name_id = BinaryNameIdLocked(thread_log, name);
            AppendBinaryRecordLocked(thread_log, 'T', task_id, thread_id, elapsed_us, async_id);
            AppendBinaryRecordLocked(thread_log, 'b', name_id, thread_id, elapsed_us, async_id);
            if (thread_log->pending.size() >= kBatchFlushThresholdBytes) {
                ShipLocked(thread_log->pending);
            }
            os_unfair_lock_unlock(&thread_log->lock);
            return;
        }
        EmitText([&](std::string &out) {
            AppendEventPrefix(out, name, 'b');
            AppendLiteral(out, ",\"id\":");
            AppendDecimal(out, async_id);
            AppendEventSuffix(out, thread_id, elapsed_us);
            AppendLiteral(out, ",\"args\":{\"task\":\"");
            AppendJSONEscaped(out, task);
            AppendLiteral(out, "\"}}");
        });
    }

    // Moves every thread's pending bytes to the writer queue, then (when
    // `sync`) waits for them to reach the mapped file and syncs it to disk.
    void Flush() {
        if (!queue_) {
            return;
        }
        DrainAllThreads();
        dispatch_sync(queue_, ^{
            log_.Flush();
        });
    }

    void SyncWait() {
        Flush();
    }

    // Called at process exit: drains everything and truncates the active
    // fragment to its real size so no zero padding is left behind.
    void Shutdown() {
        if (!queue_) {
            return;
        }
        if (drain_timer_) {
            dispatch_source_cancel(drain_timer_);
        }
        DrainAllThreads();
        dispatch_sync(queue_, ^{
            log_.Close();
        });
    }

    // Drains and deregisters the calling thread's buffer at thread exit. Called
    // from the pthread-key destructor via gActiveTrace.
    void DrainThreadOnExit(ThreadLog *thread_log) {
        if (!thread_log) {
            return;
        }

        std::lock_guard<std::mutex> guard(registry_mutex_);
        os_unfair_lock_lock(&thread_log->lock);
        ShipLocked(thread_log->pending);
        os_unfair_lock_unlock(&thread_log->lock);
        for (auto it = thread_logs_.begin(); it != thread_logs_.end(); ++it) {
            if (it->get() == thread_log) {
                thread_logs_.erase(it);  // destroys *thread_log
                break;
            }
        }
    }

private:
    bool Ready(const char *name) const {
        return IsEnabled() && name && name[0] != '\0' && queue_;
    }

    uint64_t CurrentTimeNs() const {
        const uint64_t now = mach_absolute_time();
        return now * timeinfo_.numer / timeinfo_.denom;
    }

    uint64_t ElapsedMicros() const {
        return (CurrentTimeNs() - begin_) / 1000;
    }

    void StartBackgroundDrain() {
        uint64_t interval_ms = UnsignedFromEnvironment(@"APPLETRACE_FLUSH_INTERVAL_MS", kDefaultFlushIntervalMs);
        if (interval_ms > kMaximumFlushIntervalMs) {
            interval_ms = kMaximumFlushIntervalMs;
        }
        if (interval_ms == 0) {
            return;
        }
        const uint64_t interval_ns = interval_ms * NSEC_PER_MSEC;
        drain_timer_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                              dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        if (!drain_timer_) {
            return;
        }
        dispatch_source_set_timer(drain_timer_, dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(interval_ns)),
                                  interval_ns, interval_ns / 10);
        dispatch_source_set_event_handler(drain_timer_, ^{
            DrainAllThreads();
        });
        dispatch_resume(drain_timer_);
    }

    // Ships every thread's pending bytes to the writer queue. Holding
    // registry_mutex_ prevents a thread from exiting and freeing its ThreadLog
    // mid-iteration (thread exit takes the same lock).
    void DrainAllThreads() {
        std::lock_guard<std::mutex> guard(registry_mutex_);
        for (auto &thread_log : thread_logs_) {
            os_unfair_lock_lock(&thread_log->lock);
            ShipLocked(thread_log->pending);
            os_unfair_lock_unlock(&thread_log->lock);
        }
    }

    // Hands `pending` to the serial writer queue. Must be called with the
    // owning thread buffer's lock held: shipping under the lock keeps every
    // thread's batches in order, which begin/end pairing and the binary string
    // table both rely on.
    void ShipLocked(std::string &pending) {
        if (pending.empty() || !queue_) {
            return;
        }
        auto shipped = std::make_shared<std::string>();
        shipped->swap(pending);
        pending.reserve(kBatchReserveBytes);
        dispatch_async(queue_, ^{
            log_.AddBlock(*shipped);
        });
    }

    ThreadLog *AcquireThreadLog() {
        pthread_once(&gThreadLogKeyOnce, appletrace_make_thread_log_key);
        ThreadLog *thread_log = static_cast<ThreadLog *>(pthread_getspecific(gThreadLogKey));
        if (thread_log) {
            return thread_log;
        }

        std::unique_ptr<ThreadLog> owned(new ThreadLog());
        owned->pending.reserve(kBatchReserveBytes);
        thread_log = owned.get();
        {
            std::lock_guard<std::mutex> guard(registry_mutex_);
            thread_logs_.push_back(std::move(owned));
        }
        pthread_setspecific(gThreadLogKey, thread_log);
        return thread_log;
    }

    // Hot path (text mode): formats one JSON line straight into this thread's
    // reserved buffer — no temporary strings — and ships a whole batch to the
    // writer queue only when it crosses the threshold.
    template <typename Writer>
    void EmitText(Writer &&write) {
        if (!IsEnabled() || !queue_) {
            return;
        }

        ThreadLog *thread_log = AcquireThreadLog();
        os_unfair_lock_lock(&thread_log->lock);
        write(thread_log->pending);
        thread_log->pending.push_back('\n');
        if (thread_log->pending.size() >= kBatchFlushThresholdBytes) {
            ShipLocked(thread_log->pending);
        }
        os_unfair_lock_unlock(&thread_log->lock);
    }

    void AppendEventPrefix(std::string &out, const char *name, char phase) const {
        AppendLiteral(out, "{\"name\":\"");
        AppendJSONEscaped(out, name);
        AppendLiteral(out, "\",\"cat\":\"appletrace\",\"ph\":\"");
        out.push_back(phase);
        out.push_back('"');
    }

    void AppendEventSuffix(std::string &out, uint64_t thread_id, uint64_t elapsed_us) const {
        AppendLiteral(out, ",\"pid\":");
        AppendDecimal(out, static_cast<uint64_t>(pid_));
        AppendLiteral(out, ",\"tid\":");
        AppendDecimal(out, thread_id);
        AppendLiteral(out, ",\"ts\":");
        AppendDecimal(out, elapsed_us);
    }

    // Returns this thread's id for `name`, emitting a string-definition record
    // into the thread buffer the first time the thread uses it. Caller holds the
    // thread buffer's lock. A repeat of the same pointer costs one hash lookup
    // and a strcmp — no allocation.
    uint32_t BinaryNameIdLocked(ThreadLog *thread_log, const char *name) {
        if (!name) {
            name = "";
        }
        auto cached = thread_log->pointer_ids.find(name);
        if (cached != thread_log->pointer_ids.end() && strcmp(cached->second.name.c_str(), name) == 0) {
            return cached->second.id;
        }

        std::string key(name);
        uint32_t name_id;
        auto found = thread_log->name_ids.find(key);
        if (found != thread_log->name_ids.end()) {
            name_id = found->second;
        } else {
            name_id = gBinaryNextNameId.fetch_add(1, std::memory_order_relaxed);
            thread_log->name_ids.emplace(key, name_id);
            AppendByte(thread_log->pending, kBinaryTagString);
            AppendU32(thread_log->pending, name_id);
            AppendU32(thread_log->pending, static_cast<uint32_t>(key.size()));
            thread_log->pending.append(key);
        }

        if (thread_log->pointer_ids.size() >= kMaximumPointerCacheEntries) {
            thread_log->pointer_ids.clear();
        }
        PointerNameEntry &entry = thread_log->pointer_ids[name];
        entry.id = name_id;
        entry.name.swap(key);
        return name_id;
    }

    void AppendBinaryRecordLocked(ThreadLog *thread_log, char phase, uint32_t name_id, uint64_t tid, uint64_t ts, uint64_t arg) {
        AppendByte(thread_log->pending, static_cast<uint8_t>(phase));
        AppendU32(thread_log->pending, name_id);
        AppendU64(thread_log->pending, tid);
        AppendU64(thread_log->pending, ts);
        AppendU64(thread_log->pending, arg);
    }

    void EmitBinaryEvent(char phase, const char *name, uint64_t tid, uint64_t ts, uint64_t arg) {
        if (!IsEnabled() || !queue_) {
            return;
        }
        ThreadLog *thread_log = AcquireThreadLog();
        os_unfair_lock_lock(&thread_log->lock);
        uint32_t name_id = BinaryNameIdLocked(thread_log, name);
        AppendBinaryRecordLocked(thread_log, phase, name_id, tid, ts, arg);
        if (thread_log->pending.size() >= kBatchFlushThresholdBytes) {
            ShipLocked(thread_log->pending);
        }
        os_unfair_lock_unlock(&thread_log->lock);
    }

    void EmitMetadata(const char *name, uint64_t tid, const char *value) {
        if (!queue_ || !value) {
            return;
        }
        ThreadLog *thread_log = AcquireThreadLog();
        os_unfair_lock_lock(&thread_log->lock);
        uint32_t name_id = BinaryNameIdLocked(thread_log, name);
        uint32_t value_id = BinaryNameIdLocked(thread_log, value);
        AppendByte(thread_log->pending, static_cast<uint8_t>('M'));
        AppendU32(thread_log->pending, name_id);
        AppendU64(thread_log->pending, tid);
        AppendU64(thread_log->pending, 0);
        AppendU64(thread_log->pending, value_id);
        if (thread_log->pending.size() >= kBatchFlushThresholdBytes) {
            ShipLocked(thread_log->pending);
        }
        os_unfair_lock_unlock(&thread_log->lock);
    }

    uint64_t ResolveThreadId() {
        static __thread uint64_t cached_reported_id = UINT64_MAX;
        if (cached_reported_id != UINT64_MAX) {
            return cached_reported_id;
        }

        uint64_t thread_id = 0;
        pthread_threadid_np(pthread_self(), &thread_id);
        const uint64_t reported = pthread_main_np() != 0 ? 0 : thread_id;
        cached_reported_id = reported;
        EmitThreadName(reported);
        return reported;
    }

    void EmitThreadName(uint64_t reported_thread_id) {
        if (!queue_) {
            return;
        }

        std::string thread_name;
        if (reported_thread_id == 0) {
            thread_name = "Main Thread";
        } else {
            char buffer[256] = {0};
            if (pthread_getname_np(pthread_self(), buffer, sizeof(buffer)) == 0 && buffer[0] != '\0') {
                thread_name = buffer;
            } else {
                thread_name = "Thread " + std::to_string(reported_thread_id);
            }
        }

        if (binary_) {
            EmitMetadata("thread_name", reported_thread_id, thread_name.c_str());
            return;
        }

        EmitText([&](std::string &out) {
            AppendLiteral(out, "{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":");
            AppendDecimal(out, static_cast<uint64_t>(pid_));
            AppendLiteral(out, ",\"tid\":");
            AppendDecimal(out, reported_thread_id);
            AppendLiteral(out, ",\"args\":{\"name\":\"");
            AppendJSONEscaped(out, thread_name.c_str());
            AppendLiteral(out, "\"}}");
        });
    }

    LoggerManager log_;
    dispatch_queue_t queue_ = nullptr;
    dispatch_source_t drain_timer_ = nullptr;
    uint64_t begin_ = 0;
    mach_timebase_info_data_t timeinfo_ = {};
    pid_t pid_ = 0;
    std::atomic<bool> enabled_{true};
    bool binary_ = false;
    std::mutex registry_mutex_;
    std::vector<std::unique_ptr<ThreadLog>> thread_logs_;
};

static void appletrace_thread_log_destructor(void *pointer) {
    if (gActiveTrace && pointer) {
        gActiveTrace->DrainThreadOnExit(static_cast<ThreadLog *>(pointer));
    }
}

class TraceManager {
public:
    // Intentionally leaked: the runtime must outlive static destructors so the
    // exit handler and late-exiting threads can still drain into it.
    static TraceManager &Instance() {
        static TraceManager *manager = new TraceManager();
        return *manager;
    }

    void BeginSection(const char *name) {
        trace_.WriteSection(name, 'B');
    }

    void EndSection(const char *name) {
        trace_.WriteSection(name, 'E');
    }

    void Instant(const char *name) {
        trace_.WriteInstant(name);
    }

    void Counter(const char *name, double value) {
        trace_.WriteCounter(name, value);
    }

    void AsyncBegin(const char *name, uint64_t async_id) {
        trace_.WriteAsync(name, 'b', async_id);
    }

    void AsyncEnd(const char *name, uint64_t async_id) {
        trace_.WriteAsync(name, 'e', async_id);
    }

    void AsyncBeginWithTask(const char *name, uint64_t async_id, const char *task) {
        trace_.WriteAsyncBeginWithTask(name, async_id, task);
    }

    void Flush() {
        trace_.Flush();
    }

    void SyncWait() {
        trace_.SyncWait();
    }

    void Shutdown() {
        trace_.Shutdown();
    }

    void SetEnabled(bool enabled) {
        trace_.SetEnabled(enabled);
    }

    bool IsEnabled() const {
        return trace_.IsEnabled();
    }

    const char *GetTraceDirectory() const {
        return trace_.GetTraceDirectory();
    }

private:
    TraceManager() {
        if (!trace_.Open()) {
            NSLog(@"AppleTrace: failed to initialize trace runtime");
            return;
        }
        InstallLifecycleHooks();
    }

    // Flushes when the app is backgrounded (iOS may suspend or kill it without
    // further notice) and truncates fragments at a normal exit. Notification
    // names are spelled out so the core does not link UIKit / AppKit.
    static void InstallLifecycleHooks() {
        atexit([] { TraceManager::Instance().Shutdown(); });

        NSArray<NSString *> *names = @[
            @"UIApplicationDidEnterBackgroundNotification",
            @"UIApplicationWillTerminateNotification",
            @"NSApplicationWillTerminateNotification",
        ];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter]
                addObserverForName:name
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification *note) {
                            (void)note;
                            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                                TraceManager::Instance().Flush();
                            });
                        }];
        }
    }

    Trace trace_;
};

}  // namespace appletrace

void APTBeginSection(const char *name) {
    appletrace::TraceManager::Instance().BeginSection(name);
}

void APTEndSection(const char *name) {
    appletrace::TraceManager::Instance().EndSection(name);
}

void APTInstant(const char *name) {
    appletrace::TraceManager::Instance().Instant(name);
}

void APTCounter(const char *name, double value) {
    appletrace::TraceManager::Instance().Counter(name, value);
}

void APTAsyncBegin(const char *name, uint64_t async_id) {
    appletrace::TraceManager::Instance().AsyncBegin(name, async_id);
}

void APTAsyncEnd(const char *name, uint64_t async_id) {
    appletrace::TraceManager::Instance().AsyncEnd(name, async_id);
}

void APTAsyncBeginWithTask(const char *name, uint64_t async_id, const char *task_name) {
    appletrace::TraceManager::Instance().AsyncBeginWithTask(name, async_id, task_name);
}

uint64_t APTNewAsyncID(void) {
    return appletrace::gNextAsyncId.fetch_add(1, std::memory_order_relaxed);
}

void APTSyncWait() {
    appletrace::TraceManager::Instance().SyncWait();
}

void APTFlush() {
    appletrace::TraceManager::Instance().Flush();
}

void APTSetEnabled(BOOL enabled) {
    appletrace::TraceManager::Instance().SetEnabled(enabled);
}

BOOL APTIsEnabled() {
    return appletrace::TraceManager::Instance().IsEnabled();
}

const char *APTGetTraceDirectory() {
    return appletrace::TraceManager::Instance().GetTraceDirectory();
}

namespace {

struct MethodKey {
    const void *cls;
    const void *sel;
    bool operator==(const MethodKey &other) const { return cls == other.cls && sel == other.sel; }
};

struct MethodKeyHash {
    size_t operator()(const MethodKey &key) const {
        return (reinterpret_cast<uintptr_t>(key.cls) >> 3) * 2654435761u ^ (reinterpret_cast<uintptr_t>(key.sel) >> 3);
    }
};

}  // namespace

const char *APTSectionNameForMethod(id self_object, SEL command) {
    if (!self_object || !command) {
        return "";
    }
    // Mirrors the historical `[self class]` naming: instance methods use the
    // receiver's class, class methods use the class itself.
    Class cls = object_isClass(self_object) ? (Class)self_object : [self_object class];

    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static auto *names = new std::unordered_map<MethodKey, const char *, MethodKeyHash>();
    const MethodKey key = {(__bridge const void *)cls, command};

    os_unfair_lock_lock(&lock);
    auto found = names->find(key);
    if (found != names->end()) {
        const char *name = found->second;
        os_unfair_lock_unlock(&lock);
        return name;
    }
    const char *class_name = class_getName(cls);
    const char *selector_name = sel_getName(command);
    size_t length = strlen(class_name) + strlen(selector_name) + 4;
    char *name = static_cast<char *>(malloc(length));
    if (name) {
        snprintf(name, length, "[%s %s]", class_name, selector_name);
        names->emplace(key, name);
    }
    os_unfair_lock_unlock(&lock);
    return name ? name : "";
}

@interface APTInterface : NSObject
@end

@implementation APTInterface

+ (void)syncWait {
    APTSyncWait();
}

@end

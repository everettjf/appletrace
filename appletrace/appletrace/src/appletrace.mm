//
//  appletrace.mm
//  appletrace
//

#import "appletrace.h"

#include <atomic>
#include <cstdint>
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

bool BoolFromEnvironment(NSString *key, bool fallback) {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:key];
    if (!value.length) {
        return fallback;
    }

    NSString *normalized = value.lowercaseString;
    return ![normalized isEqualToString:@"0"] &&
           ![normalized isEqualToString:@"false"] &&
           ![normalized isEqualToString:@"no"];
}

size_t BlockSizeFromEnvironment() {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"APPLETRACE_BLOCK_SIZE_MB"];
    if (!value.length) {
        return kDefaultBlockSize;
    }

    NSInteger megabytes = value.integerValue;
    if (megabytes <= 0) {
        return kDefaultBlockSize;
    }

    size_t bytes = static_cast<size_t>(megabytes) * 1024 * 1024;
    if (bytes < kMinimumBlockSize) {
        return kMinimumBlockSize;
    }
    if (bytes > kMaximumBlockSize) {
        return kMaximumBlockSize;
    }
    return bytes;
}

std::string EscapeJSONString(const char *input) {
    if (!input) {
        return "";
    }

    std::string escaped;
    for (const unsigned char *cursor = reinterpret_cast<const unsigned char *>(input); *cursor; ++cursor) {
        switch (*cursor) {
            case '\\':
                escaped += "\\\\";
                break;
            case '"':
                escaped += "\\\"";
                break;
            case '\b':
                escaped += "\\b";
                break;
            case '\f':
                escaped += "\\f";
                break;
            case '\n':
                escaped += "\\n";
                break;
            case '\r':
                escaped += "\\r";
                break;
            case '\t':
                escaped += "\\t";
                break;
            default:
                if (*cursor < 0x20) {
                    char buffer[7] = {0};
                    snprintf(buffer, sizeof(buffer), "\\u%04x", *cursor);
                    escaped += buffer;
                } else {
                    escaped.push_back(static_cast<char>(*cursor));
                }
                break;
        }
    }
    return escaped;
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

    bool AddLine(const std::string &line) {
        if (!file_cur_) {
            return false;
        }

        const size_t required = line.size() + 1;
        if (cur_size_ + required > block_size_) {
            return false;
        }

        memcpy(file_cur_, line.data(), line.size());
        file_cur_ += line.size();
        *file_cur_++ = '\n';
        cur_size_ += required;
        return true;
    }

    // Appends raw bytes verbatim (no newline). Used by the binary fragment path.
    bool AddRaw(const std::string &bytes) {
        if (!file_cur_) {
            return false;
        }
        if (cur_size_ + bytes.size() > block_size_) {
            return false;
        }
        memcpy(file_cur_, bytes.data(), bytes.size());
        file_cur_ += bytes.size();
        cur_size_ += bytes.size();
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
        std::string path = GetFilePath();
        if (!log_.Open(path.c_str())) {
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

    void AddLine(const std::string &line) {
        if (log_.AddLine(line)) {
            return;
        }

        NSLog(@"AppleTrace: rolling trace fragment");
        if (!Open()) {
            write_failures_.fetch_add(1, std::memory_order_relaxed);
            return;
        }

        if (!log_.AddLine(line)) {
            write_failures_.fetch_add(1, std::memory_order_relaxed);
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

        size_t start = 0;
        const size_t size = block.size();
        while (start < size) {
            size_t newline = block.find('\n', start);
            size_t end = (newline == std::string::npos) ? size : newline;
            if (end > start) {
                AddLine(block.substr(start, end - start));
            }
            if (newline == std::string::npos) {
                break;
            }
            start = newline + 1;
        }
    }

    static NSString *CurrentDirectory() {
        InitializeWorkDirectory();
        return work_dir_;
    }

    uint64_t WriteFailures() const {
        return write_failures_.load(std::memory_order_relaxed);
    }

private:
    void WriteBinaryHeader() {
        std::string header(kBinaryMagic, sizeof(kBinaryMagic));
        AppendU32(header, header_pid_);
        log_.AddRaw(header);
    }

    void AddRawBlock(const std::string &block) {
        if (block.empty()) {
            return;
        }
        if (log_.AddRaw(block)) {
            return;
        }

        NSLog(@"AppleTrace: rolling trace fragment");
        if (!Open()) {
            write_failures_.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        if (!log_.AddRaw(block)) {
            write_failures_.fetch_add(1, std::memory_order_relaxed);
            NSLog(@"AppleTrace: failed to write binary batch after rollover");
        }
    }

    static void InitializeWorkDirectory() {
        static dispatch_once_t once_token;
        dispatch_once(&once_token, ^{
            NSString *configured = [[[NSProcessInfo processInfo] environment] objectForKey:@"APPLETRACE_DATA_DIR"];
            NSString *root_dir = configured.length
                                     ? configured.stringByStandardizingPath
                                     : [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES)[0]
                                           stringByAppendingPathComponent:@"appletracedata"];

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
    uint32_t header_pid_ = 0;
    std::atomic<uint64_t> write_failures_{0};
};

std::atomic<int> LoggerManager::file_counter_{0};
NSString *LoggerManager::work_dir_ = nil;

class Trace;

// Per-thread accumulation buffer. The hot path appends under `lock`; APTFlush
// and thread-exit drain it. See docs/perf-batching-design.md.
struct ThreadLog {
    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    std::string pending;
    // Binary mode only: this thread's name -> globally-unique id map. Each
    // thread emits its own string definitions, so a thread only ever references
    // ids it defined — no cross-thread ordering hazard with batched flushing.
    std::unordered_map<std::string, uint32_t> name_ids;
};

static pthread_key_t gThreadLogKey;
static pthread_once_t gThreadLogKeyOnce = PTHREAD_ONCE_INIT;
static Trace *gActiveTrace = nullptr;
static std::atomic<uint32_t> gBinaryNextNameId{0};

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
            binary_ = BoolFromEnvironment(@"APPLETRACE_BINARY", false);
            pid_ = getpid();
            gActiveTrace = this;

            if (binary_) {
                log_.EnableBinary(static_cast<uint32_t>(pid_));
            }
            if (!log_.Open()) {
                return;
            }

            queue_ = dispatch_queue_create("appletrace.queue", DISPATCH_QUEUE_SERIAL);
            mach_timebase_info(&timeinfo_);
            begin_ = CurrentTimeNs();

            if (binary_) {
                EmitMetadata("process_name", 0,
                             [[NSProcessInfo processInfo] processName].UTF8String);
            } else {
                dispatch_sync(queue_, ^{
                    WriteMetadataLocked();
                    log_.Flush();
                });
            }
        });

        return queue_ != nullptr;
    }

    void SetEnabled(bool enabled) {
        enabled_.store(enabled);
    }

    bool IsEnabled() const {
        return enabled_.load();
    }

    const char *GetTraceDirectory() const {
        return LoggerManager::CurrentDirectory().UTF8String;
    }

    void WriteSection(const char *name, const char *phase) {
        if (!IsEnabled() || !name || name[0] == '\0' || !queue_) {
            return;
        }
        accepted_events_.fetch_add(1, std::memory_order_relaxed);

        const uint64_t thread_id = ResolveThreadId();
        const uint64_t elapsed_us = (CurrentTimeNs() - begin_) / 1000;
        if (binary_) {
            EmitBinaryEvent(phase[0], name, thread_id, elapsed_us, 0);
            return;
        }
        std::string line = BuildEventLine(name, phase, thread_id, elapsed_us);
        Emit(line);
    }

    void WriteInstant(const char *name) {
        if (!IsEnabled() || !name || name[0] == '\0' || !queue_) {
            return;
        }
        accepted_events_.fetch_add(1, std::memory_order_relaxed);

        const uint64_t thread_id = ResolveThreadId();
        const uint64_t elapsed_us = (CurrentTimeNs() - begin_) / 1000;
        if (binary_) {
            EmitBinaryEvent('i', name, thread_id, elapsed_us, 0);
            return;
        }
        std::string line =
            "{\"name\":\"" + EscapeJSONString(name) +
            "\",\"cat\":\"appletrace\",\"ph\":\"i\",\"pid\":" + std::to_string(pid_) +
            ",\"tid\":" + std::to_string(thread_id) + ",\"ts\":" + std::to_string(elapsed_us) +
            ",\"s\":\"t\"}";
        Emit(line);
    }

    void WriteCounter(const char *name, double value) {
        if (!IsEnabled() || !name || name[0] == '\0' || !queue_) {
            return;
        }
        accepted_events_.fetch_add(1, std::memory_order_relaxed);

        const uint64_t thread_id = ResolveThreadId();
        const uint64_t elapsed_us = (CurrentTimeNs() - begin_) / 1000;
        if (binary_) {
            uint64_t bits = 0;
            memcpy(&bits, &value, sizeof(bits));
            EmitBinaryEvent('C', name, thread_id, elapsed_us, bits);
            return;
        }
        char value_buffer[64] = {0};
        snprintf(value_buffer, sizeof(value_buffer), "%g", value);
        std::string line =
            "{\"name\":\"" + EscapeJSONString(name) +
            "\",\"cat\":\"appletrace\",\"ph\":\"C\",\"pid\":" + std::to_string(pid_) +
            ",\"tid\":" + std::to_string(thread_id) + ",\"ts\":" + std::to_string(elapsed_us) +
            ",\"args\":{\"value\":" + value_buffer + "}}";
        Emit(line);
    }

    // Nestable async events ("b"/"e"): used to track work that flows across
    // threads or dispatch queues, matched by (name, async_id).
    void WriteAsync(const char *name, const char *phase, uint64_t async_id) {
        if (!IsEnabled() || !name || name[0] == '\0' || !queue_) {
            return;
        }
        accepted_events_.fetch_add(1, std::memory_order_relaxed);

        const uint64_t thread_id = ResolveThreadId();
        const uint64_t elapsed_us = (CurrentTimeNs() - begin_) / 1000;
        if (binary_) {
            EmitBinaryEvent(phase[0], name, thread_id, elapsed_us, async_id);
            return;
        }
        std::string line =
            "{\"name\":\"" + EscapeJSONString(name) +
            "\",\"cat\":\"appletrace\",\"ph\":\"" + phase + "\",\"id\":" + std::to_string(async_id) +
            ",\"pid\":" + std::to_string(pid_) + ",\"tid\":" + std::to_string(thread_id) +
            ",\"ts\":" + std::to_string(elapsed_us) + "}";
        Emit(line);
    }

    void Flush() {
        if (!queue_) {
            return;
        }

        // Drain every thread's pending bytes, then flush the logger. Holding
        // registry_mutex_ for the whole drain prevents a thread from exiting and
        // freeing its ThreadLog mid-iteration (thread-exit takes the same lock).
        auto batches = std::make_shared<std::vector<std::string>>();
        {
            std::lock_guard<std::mutex> guard(registry_mutex_);
            for (auto &thread_log : thread_logs_) {
                os_unfair_lock_lock(&thread_log->lock);
                if (!thread_log->pending.empty()) {
                    batches->emplace_back(std::move(thread_log->pending));
                    thread_log->pending.clear();
                    thread_log->pending.reserve(kBatchReserveBytes);
                }
                os_unfair_lock_unlock(&thread_log->lock);
            }
        }

        dispatch_sync(queue_, ^{
            for (const std::string &batch : *batches) {
                log_.AddBlock(batch);
            }
            log_.Flush();
        });
    }

    void SyncWait() {
        Flush();
    }

    void GetMetrics(APTTraceMetrics *metrics) {
        if (!metrics) {
            return;
        }
        uint64_t pending_bytes = 0;
        {
            std::lock_guard<std::mutex> guard(registry_mutex_);
            for (auto &thread_log : thread_logs_) {
                os_unfair_lock_lock(&thread_log->lock);
                pending_bytes += thread_log->pending.size();
                os_unfair_lock_unlock(&thread_log->lock);
            }
        }
        metrics->accepted_events = accepted_events_.load(std::memory_order_relaxed);
        metrics->pending_bytes = pending_bytes;
        metrics->write_failures = log_.WriteFailures();
    }

    // Drains and deregisters the calling thread's buffer at thread exit. Called
    // from the pthread-key destructor via gActiveTrace.
    void DrainThreadOnExit(ThreadLog *thread_log) {
        if (!thread_log) {
            return;
        }

        std::string batch;
        {
            std::lock_guard<std::mutex> guard(registry_mutex_);
            os_unfair_lock_lock(&thread_log->lock);
            batch.swap(thread_log->pending);
            os_unfair_lock_unlock(&thread_log->lock);
            for (auto it = thread_logs_.begin(); it != thread_logs_.end(); ++it) {
                if (it->get() == thread_log) {
                    thread_logs_.erase(it);  // destroys *thread_log
                    break;
                }
            }
        }

        if (!batch.empty() && queue_) {
            auto shipped = std::make_shared<std::string>(std::move(batch));
            dispatch_async(queue_, ^{
                log_.AddBlock(*shipped);
            });
        }
    }

private:
    uint64_t CurrentTimeNs() const {
        const uint64_t now = mach_absolute_time();
        return now * timeinfo_.numer / timeinfo_.denom;
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

    // Hot path: append to this thread's buffer with no allocation, shipping a
    // whole batch to the writer queue only when it crosses the threshold.
    void Emit(const std::string &line) {
        if (!IsEnabled() || !queue_) {
            return;
        }

        ThreadLog *thread_log = AcquireThreadLog();
        std::string batch;
        {
            os_unfair_lock_lock(&thread_log->lock);
            thread_log->pending.append(line);
            thread_log->pending.push_back('\n');
            if (thread_log->pending.size() >= kBatchFlushThresholdBytes) {
                batch.swap(thread_log->pending);
                thread_log->pending.reserve(kBatchReserveBytes);
            }
            os_unfair_lock_unlock(&thread_log->lock);
        }

        ShipBatch(batch);
    }

    void ShipBatch(std::string &batch) {
        if (batch.empty() || !queue_) {
            return;
        }
        auto shipped = std::make_shared<std::string>(std::move(batch));
        dispatch_async(queue_, ^{
            log_.AddBlock(*shipped);
        });
    }

    // Returns this thread's id for `name`, emitting a string-definition record
    // into the thread buffer the first time the thread uses it. Caller holds the
    // thread buffer's lock.
    uint32_t BinaryNameIdLocked(ThreadLog *thread_log, const char *name) {
        std::string key(name ? name : "");
        auto found = thread_log->name_ids.find(key);
        if (found != thread_log->name_ids.end()) {
            return found->second;
        }
        uint32_t name_id = gBinaryNextNameId.fetch_add(1, std::memory_order_relaxed);
        thread_log->name_ids.emplace(key, name_id);
        AppendByte(thread_log->pending, kBinaryTagString);
        AppendU32(thread_log->pending, name_id);
        AppendU32(thread_log->pending, static_cast<uint32_t>(key.size()));
        thread_log->pending.append(key);
        return name_id;
    }

    void EmitBinaryEvent(char phase, const char *name, uint64_t tid, uint64_t ts, uint64_t arg) {
        if (!IsEnabled() || !queue_) {
            return;
        }
        ThreadLog *thread_log = AcquireThreadLog();
        std::string batch;
        {
            os_unfair_lock_lock(&thread_log->lock);
            uint32_t name_id = BinaryNameIdLocked(thread_log, name);
            AppendByte(thread_log->pending, static_cast<uint8_t>(phase));
            AppendU32(thread_log->pending, name_id);
            AppendU64(thread_log->pending, tid);
            AppendU64(thread_log->pending, ts);
            AppendU64(thread_log->pending, arg);
            if (thread_log->pending.size() >= kBatchFlushThresholdBytes) {
                batch.swap(thread_log->pending);
                thread_log->pending.reserve(kBatchReserveBytes);
            }
            os_unfair_lock_unlock(&thread_log->lock);
        }
        ShipBatch(batch);
    }

    void EmitMetadata(const char *name, uint64_t tid, const char *value) {
        if (!IsEnabled() || !queue_ || !value) {
            return;
        }
        ThreadLog *thread_log = AcquireThreadLog();
        std::string batch;
        {
            os_unfair_lock_lock(&thread_log->lock);
            uint32_t name_id = BinaryNameIdLocked(thread_log, name);
            uint32_t value_id = BinaryNameIdLocked(thread_log, value);
            AppendByte(thread_log->pending, static_cast<uint8_t>('M'));
            AppendU32(thread_log->pending, name_id);
            AppendU64(thread_log->pending, tid);
            AppendU64(thread_log->pending, 0);
            AppendU64(thread_log->pending, value_id);
            if (thread_log->pending.size() >= kBatchFlushThresholdBytes) {
                batch.swap(thread_log->pending);
                thread_log->pending.reserve(kBatchReserveBytes);
            }
            os_unfair_lock_unlock(&thread_log->lock);
        }
        ShipBatch(batch);
    }

    uint64_t ResolveThreadId() {
        uint64_t thread_id = 0;
        pthread_threadid_np(pthread_self(), &thread_id);
        if (main_thread_id_.load() == 0 && pthread_main_np() != 0) {
            uint64_t expected = 0;
            main_thread_id_.compare_exchange_strong(expected, thread_id);
        }
        const uint64_t reported = (thread_id == main_thread_id_.load()) ? 0 : thread_id;
        EmitThreadNameOnce(reported);
        return reported;
    }

    void EmitThreadNameOnce(uint64_t reported_thread_id) {
        static __thread bool named = false;
        if (named || !queue_) {
            return;
        }
        named = true;

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

        std::string line =
            "{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":" + std::to_string(pid_) +
            ",\"tid\":" + std::to_string(reported_thread_id) + ",\"args\":{\"name\":\"" +
            EscapeJSONString(thread_name.c_str()) + "\"}}";
        Emit(line);
    }

    std::string BuildEventLine(const char *name, const char *phase, uint64_t thread_id, uint64_t elapsed_us) const {
        std::string escaped_name = EscapeJSONString(name);
        std::string escaped_phase = EscapeJSONString(phase);
        return "{\"name\":\"" + escaped_name + "\",\"cat\":\"appletrace\",\"ph\":\"" + escaped_phase +
               "\",\"pid\":" + std::to_string(pid_) + ",\"tid\":" + std::to_string(thread_id) +
               ",\"ts\":" + std::to_string(elapsed_us) + "}";
    }

    void WriteMetadataLocked() {
        NSString *process_name = [[NSProcessInfo processInfo] processName];
        std::string line =
            "{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":" + std::to_string(pid_) +
            ",\"tid\":0,\"args\":{\"name\":\"" + EscapeJSONString(process_name.UTF8String) + "\"}}";
        log_.AddLine(line);
    }

    LoggerManager log_;
    dispatch_queue_t queue_ = nullptr;
    uint64_t begin_ = 0;
    mach_timebase_info_data_t timeinfo_ = {};
    pid_t pid_ = 0;
    std::atomic<uint64_t> main_thread_id_{0};
    std::atomic<bool> enabled_{true};
    std::atomic<uint64_t> accepted_events_{0};
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
    static TraceManager &Instance() {
        static TraceManager manager;
        return manager;
    }

    void BeginSection(const char *name) {
        trace_.WriteSection(name, "B");
    }

    void EndSection(const char *name) {
        trace_.WriteSection(name, "E");
    }

    void Instant(const char *name) {
        trace_.WriteInstant(name);
    }

    void Counter(const char *name, double value) {
        trace_.WriteCounter(name, value);
    }

    void AsyncBegin(const char *name, uint64_t async_id) {
        trace_.WriteAsync(name, "b", async_id);
    }

    void AsyncEnd(const char *name, uint64_t async_id) {
        trace_.WriteAsync(name, "e", async_id);
    }

    void Flush() {
        trace_.Flush();
    }

    void SyncWait() {
        trace_.SyncWait();
    }

    void SetEnabled(bool enabled) {
        trace_.SetEnabled(enabled);
        state_.store(enabled ? APTCaptureStateRecording : APTCaptureStateIdle,
                     std::memory_order_release);
    }

    bool IsEnabled() const {
        return trace_.IsEnabled();
    }

    const char *GetTraceDirectory() const {
        return trace_.GetTraceDirectory();
    }

    bool StartCapture() {
        APTCaptureState expected = APTCaptureStateIdle;
        if (!state_.compare_exchange_strong(expected, APTCaptureStateStarting,
                                            std::memory_order_acq_rel)) {
            return expected == APTCaptureStateRecording;
        }
        trace_.SetEnabled(true);
        state_.store(APTCaptureStateRecording, std::memory_order_release);
        return true;
    }

    void StopCapture() {
        APTCaptureState expected = APTCaptureStateRecording;
        if (!state_.compare_exchange_strong(expected, APTCaptureStateStopping,
                                            std::memory_order_acq_rel)) {
            return;
        }
        trace_.SetEnabled(false);
        state_.store(APTCaptureStateFinalizing, std::memory_order_release);
        trace_.Flush();
        state_.store(APTCaptureStateIdle, std::memory_order_release);
    }

    APTCaptureState CaptureState() const {
        return state_.load(std::memory_order_acquire);
    }

    void GetMetrics(APTTraceMetrics *metrics) {
        trace_.GetMetrics(metrics);
    }

private:
    TraceManager() {
        if (!trace_.Open()) {
            NSLog(@"AppleTrace: failed to initialize trace runtime");
        }
        state_.store(trace_.IsEnabled() ? APTCaptureStateRecording : APTCaptureStateIdle,
                     std::memory_order_release);
    }

    Trace trace_;
    std::atomic<APTCaptureState> state_{APTCaptureStateIdle};
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

BOOL APTStartCapture() {
    return appletrace::TraceManager::Instance().StartCapture();
}

void APTStopCapture() {
    appletrace::TraceManager::Instance().StopCapture();
}

APTCaptureState APTGetCaptureState() {
    return appletrace::TraceManager::Instance().CaptureState();
}

void APTGetTraceMetrics(APTTraceMetrics *metrics) {
    appletrace::TraceManager::Instance().GetMetrics(metrics);
}

@interface APTInterface : NSObject
@end

@implementation APTInterface

+ (void)syncWait {
    APTSyncWait();
}

@end

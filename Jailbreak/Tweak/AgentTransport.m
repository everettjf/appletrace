#import "AgentTransport.h"
#import "appletrace.h"

#import <arpa/inet.h>
#import <poll.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

typedef NS_ENUM(uint16_t, APTAgentMessageType) {
    APTAgentMessageHello = 1,
    APTAgentMessageCommand = 2,
    APTAgentMessageStatus = 3,
    APTAgentMessageHeartbeat = 4,
    APTAgentMessageError = 5,
};

typedef struct __attribute__((packed)) APTAgentFrameHeader {
    uint32_t magic;
    uint16_t version;
    uint16_t type;
    uint32_t payloadLength;
} APTAgentFrameHeader;

static const uint32_t APTAgentFrameMagic = 0x41505431; // "APT1"
static const uint16_t APTAgentProtocolVersion = 1;
static const uint32_t APTAgentMaximumPayload = 1024 * 1024;

static NSString *APTAgentInstanceIdentifier(void) {
    static NSString *identifier;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        identifier = NSUUID.UUID.UUIDString.lowercaseString;
    });
    return identifier;
}

static NSTimeInterval APTAgentHeartbeatInterval(void) {
    double configured = [NSProcessInfo.processInfo.environment[@"APPLETRACE_AGENT_HEARTBEAT_INTERVAL"] doubleValue];
    if (configured <= 0) return 5.0;
    return MIN(MAX(configured, 0.1), 60.0);
}

static BOOL APTWriteAll(int socketFD, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t written = write(socketFD, cursor, length);
        if (written <= 0) return NO;
        cursor += written;
        length -= (size_t)written;
    }
    return YES;
}

static BOOL APTReadAll(int socketFD, void *bytes, size_t length) {
    uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t count = read(socketFD, cursor, length);
        if (count <= 0) return NO;
        cursor += count;
        length -= (size_t)count;
    }
    return YES;
}

static BOOL APTSendJSON(int socketFD, APTAgentMessageType type, NSDictionary *payload) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!data || data.length > APTAgentMaximumPayload) return NO;
    APTAgentFrameHeader header = {
        .magic = htonl(APTAgentFrameMagic),
        .version = htons(APTAgentProtocolVersion),
        .type = htons(type),
        .payloadLength = htonl((uint32_t)data.length),
    };
    return APTWriteAll(socketFD, &header, sizeof(header)) &&
           APTWriteAll(socketFD, data.bytes, data.length);
}

static NSString *APTAgentSocketPath(void) {
    NSString *configured = NSProcessInfo.processInfo.environment[@"APPLETRACE_DAEMON_SOCKET"];
    if (configured.length) return configured;
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
        return @"/var/jb/var/run/appletraced.sock";
    }
    return @"/var/run/appletraced.sock";
}

static int APTConnectToDaemon(void) {
    int socketFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socketFD < 0) return -1;
#ifdef SO_NOSIGPIPE
    int noSignal = 1;
    setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
#endif
    struct timeval sendTimeout = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, sizeof(sendTimeout));

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    const char *path = APTAgentSocketPath().fileSystemRepresentation;
    if (strlen(path) >= sizeof(address.sun_path)) {
        close(socketFD);
        return -1;
    }
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    if (connect(socketFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(socketFD);
        return -1;
    }
    return socketFD;
}

static NSDictionary *APTAgentStatus(uint64_t connectionSequence) {
    APTTraceMetrics metrics = {0};
    APTGetTraceMetrics(&metrics);
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    NSString *bundleIdentifier = environment[@"APPLETRACE_TEST_BUNDLE_ID"] ?: NSBundle.mainBundle.bundleIdentifier;
    NSString *processName = environment[@"APPLETRACE_TEST_PROCESS_NAME"] ?: NSProcessInfo.processInfo.processName;
#if defined(__arm64e__)
    NSString *architecture = @"arm64e";
#elif defined(__arm64__)
    NSString *architecture = @"arm64";
#elif defined(__x86_64__)
    NSString *architecture = @"x86_64";
#else
    NSString *architecture = @"unknown";
#endif
    return @{
        @"instanceId": APTAgentInstanceIdentifier(),
        @"connectionSequence": @(connectionSequence),
        @"pid": @(getpid()),
        @"processName": processName ?: @"",
        @"bundleIdentifier": bundleIdentifier ?: @"",
        @"architecture": architecture,
        @"objcHookInstalled": [NSNumber numberWithBool:APTIsObjcMsgSendHookInstalled()],
        @"captureState": @(APTGetCaptureState()),
        @"acceptedEvents": @(metrics.accepted_events),
        @"pendingBytes": @(metrics.pending_bytes),
        @"writeFailures": @(metrics.write_failures),
        @"traceDirectory": [NSString stringWithUTF8String:(APTGetTraceDirectory() ?: "")],
    };
}

static void APTApplyCommand(NSDictionary *command) {
    NSString *name = command[@"command"];
    if ([name isEqualToString:@"start"]) {
        APTStartCapture();
    } else if ([name isEqualToString:@"stop"]) {
        APTStopCapture();
    } else if ([name isEqualToString:@"flush"]) {
        APTFlush();
    } else if ([name isEqualToString:@"filters"]) {
        NSArray *allow = [command[@"allowClassPrefixes"] isKindOfClass:NSArray.class]
                             ? command[@"allowClassPrefixes"] : @[];
        NSArray *deny = [command[@"denyClassPrefixes"] isKindOfClass:NSArray.class]
                            ? command[@"denyClassPrefixes"] : @[];
        APTSetObjcTraceClassFilters([[allow componentsJoinedByString:@","] UTF8String],
                                    [[deny componentsJoinedByString:@","] UTF8String]);
    }
}

static void APTAgentRun(void) {
    uint64_t connectionSequence = 0;
    useconds_t reconnectDelay = 1000000;
    for (;;) {
        @autoreleasepool {
            int socketFD = APTConnectToDaemon();
            if (socketFD < 0) {
                usleep(reconnectDelay + arc4random_uniform(250000));
                reconnectDelay = MIN(reconnectDelay * 2, (useconds_t)30000000);
                continue;
            }
            connectionSequence++;
            if (!APTSendJSON(socketFD, APTAgentMessageHello, APTAgentStatus(connectionSequence))) {
                close(socketFD);
                usleep(reconnectDelay + arc4random_uniform(250000));
                reconnectDelay = MIN(reconnectDelay * 2, (useconds_t)30000000);
                continue;
            }
            reconnectDelay = 1000000;

            for (;;) {
                struct pollfd descriptor = {.fd = socketFD, .events = POLLIN};
                int timeout = (int)(APTAgentHeartbeatInterval() * 1000.0);
                int ready = poll(&descriptor, 1, timeout);
                if (ready == 0) {
                    if (!APTSendJSON(socketFD, APTAgentMessageHeartbeat,
                                     APTAgentStatus(connectionSequence))) break;
                    continue;
                }
                if (ready < 0 || !(descriptor.revents & POLLIN)) break;
                APTAgentFrameHeader header = {0};
                if (!APTReadAll(socketFD, &header, sizeof(header))) break;
                uint32_t magic = ntohl(header.magic);
                uint16_t version = ntohs(header.version);
                uint16_t type = ntohs(header.type);
                uint32_t length = ntohl(header.payloadLength);
                if (magic != APTAgentFrameMagic || version != APTAgentProtocolVersion ||
                    length > APTAgentMaximumPayload) break;
                NSMutableData *payload = [NSMutableData dataWithLength:length];
                if (length && !APTReadAll(socketFD, payload.mutableBytes, length)) break;
                if (type == APTAgentMessageCommand) {
                    NSDictionary *command = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
                    if ([command isKindOfClass:NSDictionary.class]) APTApplyCommand(command);
                    if (!APTSendJSON(socketFD, APTAgentMessageStatus,
                                     APTAgentStatus(connectionSequence))) break;
                }
            }
            close(socketFD);
        }
        usleep(reconnectDelay + arc4random_uniform(250000));
    }
}

void APTStartAgentTransport(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            APTAgentRun();
        });
    });
}

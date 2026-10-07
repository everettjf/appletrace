#import "ControlServer.h"
#import "AgentRegistry.h"

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

static const NSUInteger APTHTTPMaximumHeader = 32 * 1024;
static const NSUInteger APTHTTPMaximumBody = 64 * 1024;
static const NSUInteger APTHTTPMaximumPath = 2048;

static BOOL APTHTTPWriteAll(int socketFD, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t written = write(socketFD, cursor, length);
        if (written <= 0) return NO;
        cursor += written;
        length -= (size_t)written;
    }
    return YES;
}

static void APTHTTPGracefulClose(int socketFD) {
    shutdown(socketFD, SHUT_WR);
    struct timeval drainTimeout = {.tv_sec = 0, .tv_usec = 100000};
    setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &drainTimeout, sizeof(drainTimeout));
    uint8_t buffer[1024];
    while (read(socketFD, buffer, sizeof(buffer)) > 0) {}
    close(socketFD);
}

static NSString *APTHTTPReason(NSInteger status) {
    switch (status) {
        case 200: return @"OK";
        case 202: return @"Accepted";
        case 400: return @"Bad Request";
        case 401: return @"Unauthorized";
        case 408: return @"Request Timeout";
        case 413: return @"Content Too Large";
        case 404: return @"Not Found";
        case 405: return @"Method Not Allowed";
        case 431: return @"Request Header Fields Too Large";
        case 503: return @"Service Unavailable";
        default: return @"Internal Server Error";
    }
}

static NSString *APTContentType(NSString *path) {
    NSString *extension = path.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"html"]) return @"text/html; charset=utf-8";
    if ([extension isEqualToString:@"css"]) return @"text/css; charset=utf-8";
    if ([extension isEqualToString:@"js"]) return @"text/javascript; charset=utf-8";
    if ([extension isEqualToString:@"svg"]) return @"image/svg+xml";
    return @"application/octet-stream";
}

@interface APTControlServer ()
@property(nonatomic, strong) APTAgentRegistry *registry;
@property(nonatomic) uint16_t port;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *consolePath;
@property(nonatomic) unsigned long long artifactQuotaBytes;
@property(nonatomic) NSUInteger artifactMaximumFiles;
@property(nonatomic) NSTimeInterval artifactSweepInterval;
@property(nonatomic) dispatch_semaphore_t clientSlots;
@property(nonatomic) dispatch_source_t artifactTimer;
- (void)sendErrorCode:(NSString *)code message:(NSString *)message status:(NSInteger)status toClient:(int)client;
- (void)startArtifactTimer;
- (void)enforceArtifactQuotaInDirectory:(NSString *)directory;
@end

@implementation APTControlServer

- (instancetype)initWithRegistry:(APTAgentRegistry *)registry
                             port:(uint16_t)port
                            token:(NSString *)token
                      consolePath:(NSString *)consolePath {
    self = [super init];
    if (self) {
        _registry = registry;
        _port = port;
        _token = [token copy];
        _consolePath = [consolePath copy];
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        long long configuredQuota = [environment[@"APPLETRACE_ARTIFACT_QUOTA_BYTES"] longLongValue];
        NSUInteger maximumFiles = [environment[@"APPLETRACE_ARTIFACT_MAX_FILES"] integerValue];
        double sweepInterval = [environment[@"APPLETRACE_ARTIFACT_SWEEP_INTERVAL"] doubleValue];
        NSInteger maximumClients = [environment[@"APPLETRACE_CONTROL_MAX_CLIENTS"] integerValue];
        _artifactQuotaBytes = configuredQuota > 0 ? (unsigned long long)configuredQuota
                                                  : 256ull * 1024ull * 1024ull;
        _artifactMaximumFiles = maximumFiles > 0 ? MIN(maximumFiles, 4096) : 128;
        _artifactSweepInterval = sweepInterval > 0 ? MAX(sweepInterval, 0.2) : 30.0;
        _clientSlots = dispatch_semaphore_create(maximumClients > 0 ? MIN(maximumClients, 128) : 32);
    }
    return self;
}

- (BOOL)run:(NSError **)error {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return NO;
    int reuse = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(self.port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(listener, 32) != 0) {
        close(listener);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    [self startArtifactTimer];
    NSLog(@"appletraced control server listening on http://127.0.0.1:%u", self.port);
    for (;;) {
        int client = accept(listener, NULL, NULL);
        if (client < 0) continue;
        struct timeval timeout = {.tv_sec = 5, .tv_usec = 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
#ifdef SO_NOSIGPIPE
        int noSignal = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
#endif
        if (dispatch_semaphore_wait(self.clientSlots, DISPATCH_TIME_NOW) != 0) {
            [self sendErrorCode:@"server_busy" message:@"Too many active clients" status:503 toClient:client];
            APTHTTPGracefulClose(client);
            continue;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self handleClient:client];
            dispatch_semaphore_signal(self.clientSlots);
        });
    }
}

- (void)handleClient:(int)client {
    @autoreleasepool {
        NSMutableData *requestData = [NSMutableData data];
        NSRange separator = NSMakeRange(NSNotFound, 0);
        NSUInteger expectedLength = NSNotFound;
        uint8_t buffer[8192];
        NSInteger parseErrorStatus = 0;
        NSString *parseErrorCode = nil;
        NSString *parseErrorMessage = nil;
        while (requestData.length <= APTHTTPMaximumHeader + APTHTTPMaximumBody) {
            ssize_t count = read(client, buffer, sizeof(buffer));
            if (count <= 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    parseErrorStatus = 408;
                    parseErrorCode = @"request_timeout";
                    parseErrorMessage = @"Request body or headers timed out";
                }
                break;
            }
            [requestData appendBytes:buffer length:(NSUInteger)count];
            separator = [requestData rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                         options:0
                                           range:NSMakeRange(0, requestData.length)];
            if (separator.location != NSNotFound) {
                if (separator.location > APTHTTPMaximumHeader) {
                    parseErrorStatus = 431;
                    parseErrorCode = @"headers_too_large";
                    parseErrorMessage = @"Request headers exceed 32 KiB";
                    break;
                }
                NSString *head = [[NSString alloc] initWithData:[requestData subdataWithRange:NSMakeRange(0, separator.location)]
                                                       encoding:NSUTF8StringEncoding];
                NSUInteger contentLength = 0;
                BOOL foundContentLength = NO;
                for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
                    if ([[line lowercaseString] hasPrefix:@"content-length:"]) {
                        NSString *value = [[line substringFromIndex:[line rangeOfString:@":"].location + 1]
                            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                        NSScanner *scanner = [NSScanner scannerWithString:value];
                        unsigned long long parsed = 0;
                        if (foundContentLength || ![scanner scanUnsignedLongLong:&parsed] || !scanner.isAtEnd) {
                            parseErrorStatus = 400;
                            parseErrorCode = @"invalid_content_length";
                            parseErrorMessage = @"Content-Length must be one non-negative integer";
                            break;
                        }
                        foundContentLength = YES;
                        if (parsed > APTHTTPMaximumBody) {
                            parseErrorStatus = 413;
                            parseErrorCode = @"body_too_large";
                            parseErrorMessage = @"Request body exceeds 64 KiB";
                            break;
                        }
                        contentLength = (NSUInteger)parsed;
                    }
                }
                if (parseErrorStatus) break;
                expectedLength = NSMaxRange(separator) + contentLength;
                if (requestData.length >= expectedLength) break;
            } else if (requestData.length > APTHTTPMaximumHeader) {
                parseErrorStatus = 431;
                parseErrorCode = @"headers_too_large";
                parseErrorMessage = @"Request headers exceed 32 KiB";
                break;
            }
        }
        if (parseErrorStatus) {
            [self sendErrorCode:parseErrorCode message:parseErrorMessage status:parseErrorStatus toClient:client];
            close(client);
            return;
        }
        if (separator.location == NSNotFound || expectedLength == NSNotFound || requestData.length < expectedLength) {
            [self sendErrorCode:@"malformed_request" message:@"Incomplete or malformed HTTP request" status:400 toClient:client];
            close(client);
            return;
        }

        NSString *head = [[NSString alloc] initWithData:[requestData subdataWithRange:NSMakeRange(0, separator.location)]
                                               encoding:NSUTF8StringEncoding];
        NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
        NSArray<NSString *> *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
        if (requestLine.count < 2) {
            [self sendErrorCode:@"malformed_request" message:@"Invalid request line" status:400 toClient:client];
            close(client);
            return;
        }
        NSString *method = requestLine[0];
        NSString *path = [requestLine[1] componentsSeparatedByString:@"?"][0];
        if (path.length == 0 || path.length > APTHTTPMaximumPath) {
            [self sendErrorCode:@"invalid_path" message:@"Request path is empty or too long" status:400 toClient:client];
            close(client);
            return;
        }
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        for (NSString *line in [lines subarrayWithRange:NSMakeRange(1, lines.count - 1)]) {
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            NSString *key = [[line substringToIndex:colon.location] lowercaseString];
            headers[key] = [[line substringFromIndex:NSMaxRange(colon)]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        NSData *body = [requestData subdataWithRange:NSMakeRange(NSMaxRange(separator), expectedLength - NSMaxRange(separator))];

        if (([path isEqualToString:@"/"] || [path hasPrefix:@"/assets/"]) && [method isEqualToString:@"GET"]) {
            [self sendAsset:path toClient:client];
        } else if (![self authorized:headers]) {
            [self sendErrorCode:@"unauthorized" message:@"A valid control token is required" status:401 toClient:client];
        } else {
            [self routeMethod:method path:path body:body toClient:client];
        }
        close(client);
    }
}

- (BOOL)authorized:(NSDictionary *)headers {
    return [headers[@"authorization"] isEqualToString:[@"Bearer " stringByAppendingString:self.token]] ||
           [headers[@"x-appletrace-token"] isEqualToString:self.token];
}

- (void)routeMethod:(NSString *)method path:(NSString *)path body:(NSData *)body toClient:(int)client {
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/v1/agents"]) {
        [self sendJSON:@{@"protocolVersion": @1, @"agents": self.registry.agentSnapshots}
                 status:200 toClient:client];
        return;
    }
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count < 5 || ![parts[1] isEqualToString:@"api"] || ![parts[2] isEqualToString:@"v1"] ||
        ![parts[3] isEqualToString:@"agents"]) {
        [self sendErrorCode:@"not_found" message:@"Resource not found" status:404 toClient:client];
        return;
    }
    NSString *identifier = [parts[4] stringByRemovingPercentEncoding];
    if ([method isEqualToString:@"GET"] && parts.count == 5) {
        NSDictionary *snapshot = [self.registry agentSnapshotWithIdentifier:identifier];
        [self sendJSON:snapshot ?: @{@"error": @"agent not found"} status:snapshot ? 200 : 404 toClient:client];
        return;
    }
    if ([method isEqualToString:@"GET"] && parts.count >= 6 && [parts[5] isEqualToString:@"artifacts"]) {
        if (parts.count == 6) {
            [self sendArtifactsForAgent:identifier toClient:client];
        } else if (parts.count == 7) {
            [self sendArtifact:[parts[6] stringByRemovingPercentEncoding]
                      forAgent:identifier
                      toClient:client];
        } else {
            [self sendErrorCode:@"not_found" message:@"Resource not found" status:404 toClient:client];
        }
        return;
    }
    if (![method isEqualToString:@"POST"] || parts.count < 6) {
        [self sendErrorCode:@"method_not_allowed" message:@"This resource does not accept that method" status:405 toClient:client];
        return;
    }
    NSString *action = parts[5];
    NSMutableDictionary *command = [@{@"command": action} mutableCopy];
    if ([action isEqualToString:@"filters"]) {
        id filters = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        if (![filters isKindOfClass:NSDictionary.class]) {
            [self sendErrorCode:@"invalid_filters" message:@"Filter payload must be a JSON object" status:400 toClient:client];
            return;
        }
        NSArray *allow = filters[@"allowClassPrefixes"] ?: @[];
        NSArray *deny = filters[@"denyClassPrefixes"] ?: @[];
        NSCharacterSet *invalid = NSCharacterSet.controlCharacterSet;
        BOOL valid = [allow isKindOfClass:NSArray.class] && [deny isKindOfClass:NSArray.class] &&
                     allow.count <= 256 && deny.count <= 256;
        if (valid) {
            for (id value in [allow arrayByAddingObjectsFromArray:deny]) {
                valid = [value isKindOfClass:NSString.class] && [value length] <= 256 &&
                        [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
                if (!valid) break;
            }
        }
        if (!valid) {
            [self sendErrorCode:@"invalid_filters" message:@"Filters must contain at most 256 short string prefixes" status:400 toClient:client];
            return;
        }
        command[@"allowClassPrefixes"] = allow;
        command[@"denyClassPrefixes"] = deny;
    } else if (![@[@"start", @"stop", @"flush"] containsObject:action]) {
        [self sendErrorCode:@"unknown_command" message:@"Unknown Agent command" status:404 toClient:client];
        return;
    }
    NSError *error = nil;
    BOOL sent = [self.registry sendCommand:command toAgentWithIdentifier:identifier error:&error];
    if (sent) {
        [self sendJSON:@{@"accepted": @YES, @"agentId": identifier} status:202 toClient:client];
    } else {
        [self sendErrorCode:@"agent_unavailable" message:error.localizedDescription ?: @"Agent command failed"
                     status:503 toClient:client];
    }
}

- (NSString *)traceDirectoryForAgent:(NSString *)identifier {
    NSString *directory = [self.registry agentSnapshotWithIdentifier:identifier][@"traceDirectory"];
    return [directory isKindOfClass:NSString.class] ? directory.stringByStandardizingPath : nil;
}

- (void)sendArtifactsForAgent:(NSString *)identifier toClient:(int)client {
    NSString *directory = [self traceDirectoryForAgent:identifier];
    if (!directory) {
        [self sendErrorCode:@"agent_not_found" message:@"Agent not found" status:404 toClient:client];
        return;
    }
    [self enforceArtifactQuotaInDirectory:directory];
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    NSMutableArray *artifacts = [NSMutableArray array];
    for (NSString *name in names) {
        if (![@[@"appletrace", @"appletracebin"] containsObject:name.pathExtension.lowercaseString]) continue;
        NSString *file = [directory stringByAppendingPathComponent:name];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:file error:nil];
        if (![attributes.fileType isEqualToString:NSFileTypeRegular]) continue;
        [artifacts addObject:@{
            @"name": name,
            @"size": attributes[NSFileSize] ?: @0,
            @"modifiedAt": @([attributes[NSFileModificationDate] timeIntervalSince1970]),
        }];
    }
    [artifacts sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [right[@"modifiedAt"] compare:left[@"modifiedAt"]];
    }];
    [self sendJSON:artifacts status:200 toClient:client];
}

- (void)sendArtifact:(NSString *)name forAgent:(NSString *)identifier toClient:(int)client {
    NSString *directory = [self traceDirectoryForAgent:identifier];
    if (!directory || !name.length || ![name isEqualToString:name.lastPathComponent] ||
        ![@[@"appletrace", @"appletracebin"] containsObject:name.pathExtension.lowercaseString]) {
        [self sendErrorCode:@"invalid_artifact" message:@"Artifact name is invalid" status:400 toClient:client];
        return;
    }
    NSString *file = [[directory stringByAppendingPathComponent:name] stringByStandardizingPath];
    if (![[file stringByDeletingLastPathComponent] isEqualToString:directory]) {
        [self sendErrorCode:@"invalid_artifact" message:@"Artifact path escapes the trace directory" status:400 toClient:client];
        return;
    }
    NSData *body = [NSData dataWithContentsOfFile:file options:NSDataReadingMappedIfSafe error:nil];
    if (!body) {
        [self sendErrorCode:@"artifact_not_found" message:@"Artifact not found" status:404 toClient:client];
        return;
    }
    [self sendBody:body contentType:@"application/octet-stream" status:200 toClient:client];
}

- (void)sendJSON:(id)value status:(NSInteger)status toClient:(int)client {
    NSData *body = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil] ?: [NSData data];
    [self sendBody:body contentType:@"application/json; charset=utf-8" status:status toClient:client];
}

- (void)sendErrorCode:(NSString *)code
               message:(NSString *)message
                status:(NSInteger)status
              toClient:(int)client {
    [self sendJSON:@{@"error": code ?: @"unknown_error", @"message": message ?: @"Request failed"}
             status:status toClient:client];
}

- (void)sendAsset:(NSString *)path toClient:(int)client {
    NSString *relative = [path isEqualToString:@"/"] ? @"index.html" : [path substringFromIndex:1];
    if ([relative containsString:@".."] || [relative hasPrefix:@"/"]) {
        [self sendErrorCode:@"invalid_asset_path" message:@"Asset path is invalid" status:400 toClient:client];
        return;
    }
    NSString *root = self.consolePath.stringByStandardizingPath;
    NSString *file = [[root stringByAppendingPathComponent:relative] stringByStandardizingPath];
    if (![[file stringByDeletingLastPathComponent] hasPrefix:root]) {
        [self sendErrorCode:@"invalid_asset_path" message:@"Asset path escapes the console root" status:400 toClient:client];
        return;
    }
    NSData *body = [NSData dataWithContentsOfFile:file];
    if (!body) {
        [self sendErrorCode:@"asset_not_found" message:@"Console asset not found" status:404 toClient:client];
        return;
    }
    [self sendBody:body contentType:APTContentType(file) status:200 toClient:client];
}

- (void)startArtifactTimer {
    self.artifactTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    uint64_t interval = (uint64_t)(self.artifactSweepInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(self.artifactTimer, dispatch_time(DISPATCH_TIME_NOW, interval), interval,
                              MIN(interval / 10, (uint64_t)NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.artifactTimer, ^{
        typeof(self) strongSelf = weakSelf;
        for (NSDictionary *agent in strongSelf.registry.agentSnapshots) {
            NSString *directory = agent[@"traceDirectory"];
            if ([directory isKindOfClass:NSString.class]) [strongSelf enforceArtifactQuotaInDirectory:directory];
        }
    });
    dispatch_resume(self.artifactTimer);
}

- (void)enforceArtifactQuotaInDirectory:(NSString *)directory {
    NSString *standardDirectory = directory.stringByStandardizingPath;
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:standardDirectory error:nil] ?: @[];
    NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
    unsigned long long total = 0;
    for (NSString *name in names) {
        if (![@[@"appletrace", @"appletracebin"] containsObject:name.pathExtension.lowercaseString]) continue;
        NSString *path = [standardDirectory stringByAppendingPathComponent:name];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if (![attributes.fileType isEqualToString:NSFileTypeRegular]) continue;
        unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
        total += size;
        [files addObject:@{@"path": path, @"size": @(size),
                           @"date": attributes[NSFileModificationDate] ?: NSDate.distantPast}];
    }
    [files sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"date"] compare:right[@"date"]];
    }];
    while (files.count > 1 &&
           (files.count > self.artifactMaximumFiles || total > self.artifactQuotaBytes)) {
        NSDictionary *oldest = files.firstObject;
        if ([[NSFileManager defaultManager] removeItemAtPath:oldest[@"path"] error:nil]) {
            total -= [oldest[@"size"] unsignedLongLongValue];
            NSLog(@"appletraced pruned trace artifact %@", oldest[@"path"]);
        }
        [files removeObjectAtIndex:0];
    }
}

- (void)sendBody:(NSData *)body contentType:(NSString *)contentType status:(NSInteger)status toClient:(int)client {
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n",
        (long)status, APTHTTPReason(status), contentType, (unsigned long)body.length];
    NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
    APTHTTPWriteAll(client, headData.bytes, headData.length);
    APTHTTPWriteAll(client, body.bytes, body.length);
}

@end

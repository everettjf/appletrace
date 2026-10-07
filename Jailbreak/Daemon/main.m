#import "AgentRegistry.h"
#import "ControlServer.h"

static NSString *APTControlToken(void) {
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    NSString *configured = environment[@"APPLETRACE_CONTROL_TOKEN"];
    if (configured.length) return configured;

    NSString *preferencesPath = @"/var/mobile/Library/Preferences/com.everettjf.appletrace.plist";
    NSMutableDictionary *preferences = [[NSDictionary dictionaryWithContentsOfFile:preferencesPath] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    configured = preferences[@"ControlToken"];
    if (configured.length) return configured;

    configured = [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""].lowercaseString;
    preferences[@"ControlToken"] = configured;
    [preferences writeToFile:preferencesPath atomically:YES];
    NSLog(@"appletraced generated ControlToken in %@", preferencesPath);
    return configured;
}

int main(void) {
    @autoreleasepool {
        NSString *socketPath = NSProcessInfo.processInfo.environment[@"APPLETRACE_DAEMON_SOCKET"];
        if (!socketPath.length) {
            socketPath = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]
                             ? @"/var/jb/var/run/appletraced.sock"
                             : @"/var/run/appletraced.sock";
        }
        APTAgentRegistry *registry = [[APTAgentRegistry alloc] initWithSocketPath:socketPath];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *registryError = nil;
            if (![registry run:&registryError]) {
                NSLog(@"appletraced Agent listener failed: %@", registryError);
                exit(1);
            }
        });

        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        uint16_t port = (uint16_t)[environment[@"APPLETRACE_CONTROL_PORT"] integerValue];
        if (!port) port = 31337;
        NSString *consolePath = environment[@"APPLETRACE_CONSOLE_PATH"];
        if (!consolePath.length) {
            consolePath = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]
                ? @"/var/jb/usr/share/appletrace/console"
                : @"/usr/share/appletrace/console";
        }
        APTControlServer *server = [[APTControlServer alloc] initWithRegistry:registry
                                                                        port:port
                                                                       token:APTControlToken()
                                                                 consolePath:consolePath];
        NSError *error = nil;
        if (![server run:&error]) {
            NSLog(@"appletraced control server failed: %@", error);
            return 1;
        }
    }
    return 0;
}

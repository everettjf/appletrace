//
//  hook_main.m
//  Host regression test for the objc_msgSend hook (macOS arm64/arm64e).
//
//  Installs the hook, sends messages from this image, then dlopen()s a plugin
//  that was not loaded when the hook was installed and calls into it. The
//  accompanying script asserts both images' sends were traced and that the
//  ABI survived (return values checked here).
//

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

#import "appletrace.h"

@interface APTHostProbe : NSObject
- (double)sumA:(double)a b:(double)b c:(double)c d:(double)d e:(double)e f:(double)f g:(double)g h:(double)h i:(double)i;
- (NSString *)ping;
@end

@implementation APTHostProbe
- (double)sumA:(double)a b:(double)b c:(double)c d:(double)d e:(double)e f:(double)f g:(double)g h:(double)h i:(double)i {
    return a + b + c + d + e + f + g + h + i;
}
- (NSString *)ping {
    return @"pong";
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: hook_main <plugin.dylib>\n");
            return 2;
        }
        if (!APTInstallObjcMsgSendHook()) {
            fprintf(stderr, "hook install failed\n");
            return 1;
        }
        APTHostProbe *probe = [APTHostProbe new];
        double sum = [probe sumA:1 b:2 c:3 d:4 e:5 f:6 g:7 h:8 i:9];
        NSString *reply = [probe ping];
        if (sum != 45.0 || ![reply isEqualToString:@"pong"]) {
            fprintf(stderr, "ABI check failed: sum=%f reply=%s\n", sum, reply.UTF8String);
            return 1;
        }

        void *plugin = dlopen(argv[1], RTLD_NOW);
        if (!plugin) {
            fprintf(stderr, "dlopen failed: %s\n", dlerror());
            return 1;
        }
        int (*run)(void) = (int (*)(void))dlsym(plugin, "apt_plugin_run");
        if (!run || run() != 42) {
            fprintf(stderr, "plugin call failed\n");
            return 1;
        }
        APTFlush();
        printf("TRACE_DIR=%s\n", APTGetTraceDirectory());
    }
    return 0;
}

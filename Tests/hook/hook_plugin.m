//
//  hook_plugin.m
//  Loaded with dlopen() after the objc_msgSend hook is installed.
//

#import <Foundation/Foundation.h>

@interface APTLatePlugin : NSObject
- (int)answer;
@end

@implementation APTLatePlugin
- (int)answer {
    return 42;
}
@end

__attribute__((visibility("default"))) int apt_plugin_run(void) {
    APTLatePlugin *plugin = [APTLatePlugin new];
    return [plugin answer];
}

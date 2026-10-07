#import <Foundation/Foundation.h>

@interface APTLateLoadedProbe : NSObject
- (void)run;
@end

@implementation APTLateLoadedProbe
- (void)run {
    // Keep a real Objective-C message send in this image. The experimental
    // smoke test loads the dylib after hook installation and asserts that the
    // add-image callback rebinds this image's objc_msgSend import.
    (void)[@"appletrace-late-load" length];
}
@end

__attribute__((visibility("default")))
void APTInvokeLateLoadedProbe(void) {
    APTLateLoadedProbe *probe = [[APTLateLoadedProbe alloc] init];
    [probe run];
}

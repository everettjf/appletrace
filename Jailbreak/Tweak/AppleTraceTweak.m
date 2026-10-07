#import "AgentTransport.h"
#import "appletrace.h"

static BOOL APTBundleIsEnabled(void) {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (!bundleIdentifier.length) return NO;

    NSString *preferencesPath = @"/var/mobile/Library/Preferences/com.everettjf.appletrace.plist";
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:preferencesPath];
    NSArray *enabledBundles = [preferences[@"EnabledBundles"] isKindOfClass:NSArray.class]
                                  ? preferences[@"EnabledBundles"] : @[];
    return [enabledBundles containsObject:bundleIdentifier];
}

__attribute__((constructor))
static void APTAppleTraceTweakInitialize(void) {
    @autoreleasepool {
        if (!APTBundleIsEnabled()) return;
        APTSetEnabled(NO);
        APTInstallObjcMsgSendHook();
        APTStartAgentTransport();
    }
}

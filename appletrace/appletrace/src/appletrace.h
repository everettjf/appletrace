//
//  appletrace.h
//  appletrace
//

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void APTBeginSection(const char *name);
FOUNDATION_EXPORT void APTEndSection(const char *name);
FOUNDATION_EXPORT void APTInstant(const char *name);
FOUNDATION_EXPORT void APTCounter(const char *name, double value);
FOUNDATION_EXPORT void APTAsyncBegin(const char *name, uint64_t async_id);
FOUNDATION_EXPORT void APTAsyncEnd(const char *name, uint64_t async_id);
FOUNDATION_EXPORT void APTSyncWait(void);
FOUNDATION_EXPORT void APTFlush(void);
FOUNDATION_EXPORT void APTSetEnabled(BOOL enabled);
FOUNDATION_EXPORT BOOL APTIsEnabled(void);
FOUNDATION_EXPORT const char *APTGetTraceDirectory(void);

typedef NS_ENUM(uint32_t, APTCaptureState) {
    APTCaptureStateIdle = 0,
    APTCaptureStateStarting = 1,
    APTCaptureStateRecording = 2,
    APTCaptureStateStopping = 3,
    APTCaptureStateFinalizing = 4,
};

typedef struct APTTraceMetrics {
    uint64_t accepted_events;
    uint64_t pending_bytes;
    uint64_t write_failures;
} APTTraceMetrics;

FOUNDATION_EXPORT BOOL APTStartCapture(void);
FOUNDATION_EXPORT void APTStopCapture(void);
FOUNDATION_EXPORT APTCaptureState APTGetCaptureState(void);
FOUNDATION_EXPORT void APTGetTraceMetrics(APTTraceMetrics *metrics);
FOUNDATION_EXPORT BOOL APTInstallObjcMsgSendHook(void);
FOUNDATION_EXPORT BOOL APTIsObjcMsgSendHookInstalled(void);
/// Updates the automatic Objective-C hook's class-prefix filters at runtime.
/// Each argument is a comma-separated UTF-8 list. NULL or an empty string means
/// no prefixes. Existing calls finish with the filter snapshot they started
/// with; subsequent cache lookups use the new configuration.
FOUNDATION_EXPORT void APTSetObjcTraceClassFilters(const char *allow_prefixes,
                                                   const char *deny_prefixes);

#ifdef __OBJC__
#define APTCurrentSectionName [NSString stringWithFormat:@"[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd)].UTF8String
#define APTBegin APTBeginSection(APTCurrentSectionName)
#define APTEnd APTEndSection(APTCurrentSectionName)
#endif

#ifdef __cplusplus
namespace appletrace {
class ScopedSection {
public:
    explicit ScopedSection(const char *name) : name_(name) {
        APTBeginSection(name_);
    }

    ~ScopedSection() {
        APTEndSection(name_);
    }

private:
    const char *name_;
};
}  // namespace appletrace

#define APT_SCOPE_SECTION_IMPL(name, line) appletrace::ScopedSection __apt_scoped_section_##line(name)
#define APTScopeSection(name) APT_SCOPE_SECTION_IMPL(name, __LINE__)
#endif

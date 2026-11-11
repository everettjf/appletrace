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
/// Returns a process-unique id for APTAsyncBegin / APTAsyncEnd pairs.
FOUNDATION_EXPORT uint64_t APTNewAsyncID(void);
FOUNDATION_EXPORT void APTSyncWait(void);
FOUNDATION_EXPORT void APTFlush(void);
FOUNDATION_EXPORT void APTSetEnabled(BOOL enabled);
FOUNDATION_EXPORT BOOL APTIsEnabled(void);
FOUNDATION_EXPORT const char *APTGetTraceDirectory(void);
/// Installs the objc_msgSend / objc_msgSendSuper2 hook. Returns NO on
/// architectures other than arm64 / arm64e, where the hook is unavailable.
FOUNDATION_EXPORT BOOL APTInstallObjcMsgSendHook(void);
FOUNDATION_EXPORT BOOL APTIsObjcMsgSendHookInstalled(void);
/// One-line summary of the hook's rebinding (images scanned, GOT slots
/// rebound, protection failures) for troubleshooting.
FOUNDATION_EXPORT const char *APTObjcMsgSendHookDiagnostics(void);

#ifdef __OBJC__
/// Interned "[ClassName selector]" for the current method. The string is
/// built once per (class, selector) and reused, so APTBegin / APTEnd do not
/// allocate after the first call.
FOUNDATION_EXPORT const char *APTSectionNameForMethod(id self_object, SEL command);
#define APTCurrentSectionName APTSectionNameForMethod(self, _cmd)
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

#define APT_SCOPE_SECTION_CONCAT(a, b) a##b
#define APT_SCOPE_SECTION_IMPL(name, line) appletrace::ScopedSection APT_SCOPE_SECTION_CONCAT(__apt_scoped_section_, line)(name)
#define APTScopeSection(name) APT_SCOPE_SECTION_IMPL(name, __LINE__)
#endif

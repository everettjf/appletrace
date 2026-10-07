#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts one background connection to appletraced. The transport owns no hook
/// logic and only invokes the bounded AppleTrace capture/filter API.
FOUNDATION_EXPORT void APTStartAgentTransport(void);

NS_ASSUME_NONNULL_END

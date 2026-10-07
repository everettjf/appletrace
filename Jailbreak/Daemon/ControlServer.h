#import <Foundation/Foundation.h>

@class APTAgentRegistry;

NS_ASSUME_NONNULL_BEGIN

@interface APTControlServer : NSObject
- (instancetype)initWithRegistry:(APTAgentRegistry *)registry
                             port:(uint16_t)port
                            token:(NSString *)token
                      consolePath:(NSString *)consolePath;
- (BOOL)run:(NSError **)error;
@end

NS_ASSUME_NONNULL_END

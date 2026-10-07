#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface APTAgentRegistry : NSObject
- (instancetype)initWithSocketPath:(NSString *)socketPath;
- (BOOL)run:(NSError **)error;
- (NSArray<NSDictionary *> *)agentSnapshots;
- (nullable NSDictionary *)agentSnapshotWithIdentifier:(NSString *)identifier;
- (BOOL)sendCommand:(NSDictionary *)command
  toAgentWithIdentifier:(NSString *)identifier
                  error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END

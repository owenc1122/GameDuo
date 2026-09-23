#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface ROMArchive : NSObject
+ (BOOL)extractURL:(NSURL *)source toDirectory:(NSURL *)destination error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END

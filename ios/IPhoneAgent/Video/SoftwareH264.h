#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Confined to H264Decoder.queue. OpenH264 performs CPU decoding in the app process.
@interface SoftwareH264 : NSObject
@property(nonatomic, readonly) NSInteger lastStatus;
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;
@property(nonatomic, readonly) uint64_t outputTimestamp;
- (nullable NSData *)decode:(NSData *)annexB timestamp:(uint64_t)timestamp jpegQuality:(double)quality emit:(BOOL)emit;
- (void)reset;
@end
NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AzaharButton) {
    AzaharButtonB = 0,
    AzaharButtonY = 1,
    AzaharButtonSelect = 2,
    AzaharButtonStart = 3,
    AzaharButtonUp = 4,
    AzaharButtonDown = 5,
    AzaharButtonLeft = 6,
    AzaharButtonRight = 7,
    AzaharButtonA = 8,
    AzaharButtonX = 9,
    AzaharButtonL = 10,
    AzaharButtonR = 11,
    AzaharButtonZL = 12,
    AzaharButtonZR = 13,
    AzaharButtonHome = 14,
};

@interface AzaharCoreBridge : NSObject
// PSP IOSurface-backed frames. The consumer retains buffers until presented.
@property (nonatomic, copy, nullable) void (^pixelBufferHandler)(CVPixelBufferRef frame, BOOL flipped);

// rgba describes this frame's byte layout; false means BGRA/XRGB.
@property (nonatomic, copy, nullable) void (^videoHandler)(NSData *frame,
                                                            NSUInteger width,
                                                            NSUInteger height,
                                                            NSUInteger pitch,
                                                            BOOL rgba);
@property (nonatomic, copy, nullable) void (^audioHandler)(NSData *stereoSamples,
                                                            double sampleRate);
@property (nonatomic, copy, nullable) void (^messageHandler)(NSString *message);
@property (nonatomic, copy, nullable) void (^exitHandler)(void);

@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) double frameDuration;
@property (nonatomic, readonly) double sampleRate;

- (BOOL)startWithROMURL:(NSURL *)romURL
        systemDirectory:(NSURL *)systemDirectory
          saveDirectory:(NSURL *)saveDirectory
                  error:(NSError **)error;
+ (nullable NSDictionary<NSString *, NSString *> *)installPackageURL:(NSURL *)url
                                                     saveDirectory:(NSURL *)directory error:(NSError **)error;
- (void)savePersistentData;
- (nullable NSData *)serializeStateWithError:(NSError **)error;
- (BOOL)loadStateData:(NSData *)data error:(NSError **)error;
- (void)setCheatAtIndex:(NSUInteger)index enabled:(BOOL)enabled code:(NSString *)code;
- (void)resetCheats;
- (void)setCoreOptionValue:(NSString *)value forKey:(NSString *)key;
- (void)runFrame;
- (void)stop;
- (void)setButton:(AzaharButton)button pressed:(BOOL)pressed;
- (void)setCirclePadX:(double)x y:(double)y;
// Raw libretro joypad id (0…15, e.g. L2 = 12, R2 = 13, L3 = 14, R3 = 15).
- (void)setJoypadID:(NSUInteger)joypadID pressed:(BOOL)pressed;
// Right analog stick, −1…1 (libretro: +Y is down).
- (void)setRightAnalogX:(double)x y:(double)y;
- (void)setTouchX:(double)x y:(double)y pressed:(BOOL)pressed;

@end

NS_ASSUME_NONNULL_END

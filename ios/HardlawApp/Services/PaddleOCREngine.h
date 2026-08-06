#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface PaddleOCREngine : NSObject
- (nullable instancetype)initWithDetModel:(nonnull NSString*)detPath
                              detParams:(nonnull NSString*)detParamsPath
                               recModel:(nonnull NSString*)recPath
                              recParams:(nonnull NSString*)recParamsPath
                               dictPath:(nonnull NSString*)dictPath;
- (nonnull NSArray<NSString*>*)recognize:(nonnull CGImageRef)image
                                   error:(NSError* _Nullable * _Nullable)error;
@property (nonatomic, readonly) BOOL isLoaded;
@end

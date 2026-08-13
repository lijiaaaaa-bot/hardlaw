#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

/// PaddleOCR Lite C++ inference engine for Chinese legal documents.
/// Arm64 device only; simulator gets a stub.
@interface PaddleOCREngine : NSObject
- (nullable instancetype)initWithDetModel:(nonnull NSString*)detPath
                               recModel:(nonnull NSString*)recPath
                                dictPath:(nonnull NSString*)dictPath;
- (nonnull NSArray<NSString*>*)recognize:(nonnull CGImageRef)image
                                   error:(NSError* _Nullable * _Nullable)error;
@property (nonatomic, readonly) BOOL isLoaded;
@end

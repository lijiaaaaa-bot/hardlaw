#import "PaddleOCREngine.h"
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#if !TARGET_OS_SIMULATOR
#import "paddle_api.h"
#include <vector>
#include <algorithm>
using namespace paddle::lite_api;
static const int kDetMaxDim=960, kRecH=48, kRecW=320;
static const float kDetThresh=0.3f, kMean[3]={0.5f,0.5f,0.5f}, kStd[3]={0.5f,0.5f,0.5f};

static void ImageToBuffer(CGImageRef img, int w, int h, std::vector<float>& buf) {
    buf.resize(3*h*w); size_t bpr=w*4;
    std::vector<uint8_t> rgba(w*h*4);
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate(rgba.data(),w,h,8,bpr,cs,kCGImageAlphaNoneSkipLast|kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx,CGRectMake(0,0,w,h),img); CGColorSpaceRelease(cs); CGContextRelease(ctx);
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){int s=(y*w+x)*4,off=y*w+x;
        float r=rgba[s]/255.f,g=rgba[s+1]/255.f,b=rgba[s+2]/255.f;
        buf[off]=(b-kMean[0])/kStd[0];buf[h*w+off]=(g-kMean[1])/kStd[1];buf[2*h*w+off]=(r-kMean[2])/kStd[2];}
}

struct Box{int x,y,w,h;};
static std::vector<Box> ProbToBoxes(const float* m,int H,int W,int ow,int oh,float th){
    std::vector<Box> b; int N=H*W; std::vector<uint8_t> mask(N,0);
    for(int i=0;i<N;i++)mask[i]=m[i]>th?255:0; int minA=N/500;
    std::vector<bool> seen(N,false); const int dy[]={-1,0,1,0},dx[]={0,1,0,-1};
    for(int y=0;y<H;y++)for(int x=0;x<W;x++){int idx=y*W+x; if(!mask[idx]||seen[idx])continue;
        int x0=x,x1=x,y0=y,y1=y,cnt=0; std::vector<int> s={idx}; seen[idx]=true;
        while(!s.empty()){int c=s.back();s.pop_back();int cy=c/W,cx=c%W;cnt++;
            x0=std::min(x0,cx);x1=std::max(x1,cx);y0=std::min(y0,cy);y1=std::max(y1,cy);
            for(int d=0;d<4;d++){int ny=cy+dy[d],nx=cx+dx[d]; if(ny>=0&&ny<H&&nx>=0&&nx<W){int ni=ny*W+nx; if(mask[ni]&&!seen[ni]){seen[ni]=true;s.push_back(ni);}}}}
        if(cnt>=minA)b.push_back({(int)(x0*ow/(float)W),(int)(y0*oh/(float)H),(int)((x1-x0)*ow/(float)W),(int)((y1-y0)*oh/(float)H)});}
    std::sort(b.begin(),b.end(),[](const Box&a,const Box&b){int ra=a.y/20,rb=b.y/20;return ra!=rb?ra<rb:a.x<b.x;});
    return b;
}

static NSString* CTCDecode(const float* l,int T,int C,NSArray<NSString*>* d){
    int last=-1,bl=0; NSMutableString* s=[NSMutableString string];
    for(int t=0;t<T;t++){const float*p=l+t*C;int best=0;float bp=p[0];
        for(int c=1;c<C;c++)if(p[c]>bp){bp=p[c];best=c;}
        if(best!=bl&&best!=last&&best<(int)d.count)[s appendString:d[best]];last=best;}
    return s;
}

@implementation PaddleOCREngine {
    std::shared_ptr<PaddlePredictor> _det, _rec;
    NSArray<NSString*>* _dict;
}
- (instancetype)initWithDetModel:(NSString*)dp recModel:(NSString*)rp dictPath:(NSString*)dict {
    if(!(self=[super init]))return nil;
    MobileConfig dc;dc.set_model_from_file(dp.UTF8String);dc.set_threads(2);dc.set_power_mode(LITE_POWER_HIGH);
    _det=CreatePaddlePredictor<MobileConfig>(dc); if(!_det){NSLog(@"[PaddleOCR] det FAIL");return nil;}
    MobileConfig rc;rc.set_model_from_file(rp.UTF8String);rc.set_threads(2);rc.set_power_mode(LITE_POWER_HIGH);
    _rec=CreatePaddlePredictor<MobileConfig>(rc); if(!_rec){NSLog(@"[PaddleOCR] rec FAIL");return nil;}
    NSString* dc=[NSString stringWithContentsOfFile:dict encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray* a=[NSMutableArray arrayWithObject:@" "];[a addObjectsFromArray:[dc componentsSeparatedByString:@"\n"]];
    _dict=a;_isLoaded=YES;NSLog(@"[PaddleOCR] Ready dict=%lu",(unsigned long)_dict.count);return self;
}
- (NSArray<NSString*>*)recognize:(CGImageRef)img error:(NSError**)err {
    int ow=(int)CGImageGetWidth(img),oh=(int)CGImageGetHeight(img);
    float s=std::min(kDetMaxDim/(float)ow,kDetMaxDim/(float)oh);
    int dw=((int)(ow*s)+31)/32*32,dh=((int)(oh*s)+31)/32*32;
    std::vector<float> db;ImageToBuffer(img,dw,dh,db);
    auto dt=_det->GetInput(0);dt->Resize({1,3,dh,dw});dt->CopyFromCpu(db.data());_det->Run();
    auto dout=_det->GetOutput(0);auto ds=dout->shape();int dsz=1;for(auto x:ds)dsz*=(int)x;
    std::vector<float> dd(dsz);std::copy_n(dout->data<float>(),dsz,dd.begin());
    auto boxes=ProbToBoxes(dd.data(),dh,dw,ow,oh,kDetThresh);
    NSMutableArray* r=[NSMutableArray array];
    for(auto& b:boxes){if(b.w<4||b.h<4)continue;CGRect cr=CGRectMake(b.x,b.y,b.w,b.h);
        CGImageRef crop=CGImageCreateWithImageInRect(img,cr);if(!crop)continue;
        std::vector<float> rb;ImageToBuffer(crop,kRecW,kRecH,rb);CGImageRelease(crop);
        auto rt=_rec->GetInput(0);rt->Resize({1,3,kRecH,kRecW});rt->CopyFromCpu(rb.data());_rec->Run();
        auto rout=_rec->GetOutput(0);auto rs=rout->shape();
        if(rs.size()>=3){int T=(int)rs[1],C=(int)rs[2];
            std::vector<float> rd(T*C);std::copy_n(rout->data<float>(),T*C,rd.begin());
            NSString* t=CTCDecode(rd.data(),T,C,_dict);if(t.length)[r addObject:t];}}
    return r;
}
@end
#else
@implementation PaddleOCREngine
- (instancetype)initWithDetModel:(NSString*)dp recModel:(NSString*)rp dictPath:(NSString*)dict {
    if(!(self=[super init]))return nil; _isLoaded=NO; return self;
}
- (NSArray<NSString*>*)recognize:(CGImageRef)img error:(NSError**)err {
    if(err)*err=[NSError errorWithDomain:@"PaddleOCR" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"Only available on device"}];
    return @[];
}
@end
#endif

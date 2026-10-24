// Offscreen CARenderer consumer using the exact native Dock image helpers.
// No NSApplication, visible window, system Dock entry point, or display mode changes.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <sys/mman.h>
#include <stdio.h>
#include <unistd.h>

typedef void* (*GetState)(CGContextRef);
typedef void (*SetAccel)(void*,bool);
static BOOL cpuGate=NO;
static void releasePixels(void *info,const void *data,size_t bytes){munmap((void *)data,bytes);}
typedef id(*CGNative)(BOOL,size_t,size_t,int,void(^)(CGContextRef));
typedef void*(*CANative)(size_t,size_t,int,void(^)(CGContextRef));
static CGNative nativeCG;
static CANative nativeCA;
static CGImageRef sourceCG;
static BOOL drawSource;
static CGImageRef tinyImage(size_t size,unsigned seed) {
  void(^draw)(CGContextRef)=^(CGContextRef ctx){
    CGContextClearRect(ctx,CGRectMake(0,0,size,size));
    if(drawSource)CGContextDrawImage(ctx,CGRectMake(0,0,size,size),sourceCG);
    else {CGContextSetRGBFillColor(ctx,(seed%7)/7.,.3,.8,.8);CGContextFillRect(ctx,CGRectMake(0,0,size,size));}
    CGContextFlush(ctx);
  };
  CGImageRef image;
  if(seed%3<2) {image=(CGImageRef)nativeCG(seed%3,size,size,54,draw);CFRetain(image);}
  else {
    void *raw=nativeCA(size,size,54,draw);
    CGImageRef(*copy)(void*)=dlsym(RTLD_DEFAULT,"CARenderImageCopyCGImage");void(*release)(void*)=dlsym(RTLD_DEFAULT,"CARenderRelease");
    image=copy(raw);release(raw);
  }
  return image;
}
@interface ProbeLayer: CALayer
@property(nonatomic) CGImageRef source;
@end
@implementation ProbeLayer
-(void)drawInContext:(CGContextRef)ctx {
  if(cpuGate) { GetState get=(GetState)dlsym(RTLD_DEFAULT,"CGContextGetRenderingState");SetAccel set=(SetAccel)dlsym(RTLD_DEFAULT,"CGRenderingStateSetAllowsAcceleration");if(get&&set)set(get(ctx),false); }
  CGContextSetInterpolationQuality(ctx,kCGInterpolationHigh);
  CGContextDrawImage(ctx,self.bounds,self.source);
}
@end
static unsigned long long hashBytes(const void *p,size_t size){unsigned long long h=1469598103934665603ULL;const unsigned char *b=p;for(size_t i=0;i<size;i++)h=(h^b[i])*1099511628211ULL;return h;}
int main(int argc,const char **argv) { if(argc<2){fprintf(stderr,"usage: %s converted.dylib [default|ci-draw|draw] [frames]\n",argv[0]);return 64;}alarm(45); @autoreleasepool {
  if(getenv("LP_SW_CG")) { CFPreferencesSetAppValue(CFSTR("CAEnableMetalWhippet"),kCFBooleanFalse,kCFPreferencesCurrentApplication); Boolean exists=false; Boolean value=CFPreferencesGetAppBooleanValue(CFSTR("CAEnableMetalWhippet"),kCFPreferencesCurrentApplication,&exists);printf("in-process CAEnableMetalWhippet=%d exists=%d\n",value,exists); }
  void*h=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!h){puts(dlerror());return 9;}Dl_info inf;dladdr((void*)method_getImplementation(class_getInstanceMethod(objc_getClass("Springboard"),sel_registerName("scaleFactorChanged"))),&inf);nativeCG=(CGNative)((uintptr_t)inf.dli_fbase+0x1099f);nativeCA=(CANative)((uintptr_t)inf.dli_fbase+0x19204);
  cpuGate=argc>2 && strstr(argv[2],"cpu")!=NULL;
  BOOL custom=argc>2 && strstr(argv[2],"draw")!=NULL;
  int n=argc>3?atoi(argv[3]):120;
  drawSource=argc>2&&strstr(argv[2],"ci");
  CIContext *ci=[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@NO}];
  CIImage *im=[[CIImage imageWithColor:[CIColor colorWithRed:.3 green:.6 blue:.9 alpha:.8]] imageByCroppingToRect:CGRectMake(0,0,128,128)];
  CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  sourceCG=[ci createCGImage:im fromRect:im.extent format:kCIFormatRGBA8 colorSpace:cs deferred:YES];CGColorSpaceRelease(cs);
  id<MTLDevice> dev=MTLCreateSystemDefaultDevice();if(!dev){puts("no Metal device");return 2;}
  id<MTLCommandQueue> queue=[dev newCommandQueue];
  MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:128 height:128 mipmapped:NO];
  desc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;desc.storageMode=MTLStorageModeManaged;
  id<MTLTexture> texture=[dev newTextureWithDescriptor:desc];
  CARenderer *renderer=[CARenderer rendererWithMTLTexture:texture options:@{kCARendererMetalCommandQueue:queue}];
  CALayer *root=[CALayer layer];root.bounds=CGRectMake(0,0,128,128);root.position=CGPointMake(64,64);
  ProbeLayer *child=[ProbeLayer layer];child.bounds=CGRectMake(0,0,64,64);child.position=CGPointMake(64,64);child.contentsGravity=kCAGravityResize;
  child.masksToBounds=NO;child.shouldRasterize=YES;child.shadowOpacity=0.5;child.shadowRadius=4;child.shadowOffset=CGSizeMake(1,1);
  [root addSublayer:child];renderer.layer=root;renderer.bounds=root.bounds;
  CGImageRef held[1]={0};unsigned long long hash=0;
  printf("device=%s mode=%s CA_NO_ACCEL=%s count=%d\n",dev.name.UTF8String,argc>2?argv[2]:"default",getenv("CA_NO_ACCEL"),n);fflush(stdout);
  for(int i=0;i<n;i++) { @autoreleasepool {
    size_t srcsize=i%6<2?2:(i%6<4?11:128);
    CGImageRef img=tinyImage(srcsize,i);
    [CATransaction begin];[CATransaction setDisableActions:YES];
    child.bounds=CGRectMake(0,0,(i%3)*24+32,(i%3)*24+32);child.contentsScale=i%2?2:1;child.rasterizationScale=child.contentsScale;
    if(custom){child.source=img;[child setNeedsDisplay];[child displayIfNeeded];} else child.contents=(__bridge id)img;
    [CATransaction commit];[CATransaction flush];
    if(i%8==0){desc.width=128+(i%3)*64;desc.height=desc.width;texture=[dev newTextureWithDescriptor:desc];[renderer setDestination:texture];renderer.bounds=CGRectMake(0,0,desc.width,desc.height);}
    CFTimeInterval t=CACurrentMediaTime();[renderer beginFrameAtTime:t timeStamp:NULL];[renderer addUpdateRect:renderer.bounds];[renderer render];[renderer endFrame];
    if(held[0])CGImageRelease(held[0]);held[0]=img;
    if(i%16==0){id<MTLCommandBuffer> cb=[queue commandBuffer];[cb commit];[cb waitUntilCompleted];if(cb.error){printf("command buffer error %s\n",cb.error.description.UTF8String);return 3;}}
    if(i%100==0){printf("i=%d\n",i);fflush(stdout);}
  }}
  id<MTLCommandBuffer> final=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=[final blitCommandEncoder];[blit synchronizeResource:texture];[blit endEncoding];[final commit];[final waitUntilCompleted];
  size_t row=texture.width*4,len=row*texture.height;void *pixels=malloc(len);[texture getBytes:pixels bytesPerRow:row fromRegion:MTLRegionMake2D(0,0,texture.width,texture.height) mipmapLevel:0];hash=hashBytes(pixels,len);free(pixels);
  sleep(1);printf("done lastFrameHash=%016llx\n",hash);
  renderer.layer=nil;child.contents=nil;child.source=NULL;for(int i=0;i<1;i++)if(held[i])CGImageRelease(held[i]);
  CGImageRelease(sourceCG);return 0;
}}

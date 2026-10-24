// Hash-guarded Dock 2427.6 x86_64 helper offsets: CGImage 0x1099f, CARenderImage 0x19204.
// Pure child-process probe; no main Dock initialization, preferences, windows, or display changes.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
typedef id(*CGNative)(BOOL,size_t,size_t,int,void(^)(CGContextRef));
typedef void*(*CANative)(size_t,size_t,int,void(^)(CGContextRef));
typedef CGImageRef(*CACopy)(void*);
typedef void(*CARelease)(void*);
static uint64_t hashbytes(const uint8_t*p,size_t n){uint64_t h=1469598103934665603ULL;for(size_t i=0;i<n;i++){h^=p[i];h*=1099511628211ULL;}return h;}
static void printprot(void *data){mach_vm_address_t a=(mach_vm_address_t)data;mach_vm_size_t z;vm_region_basic_info_data_64_t info;mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;mach_port_t obj; kern_return_t kr=mach_vm_region(mach_task_self(),&a,&z,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&obj);fprintf(stderr,"data=%p region=%llx/%llx prot=%x max=%x kr=%d ",data,a,z,info.protection,info.max_protection,kr);}
static uint64_t imagehash(CGImageRef image){CGDataProviderRef p=CGImageGetDataProvider(image);CFDataRef d=CGDataProviderCopyData(p);if(!d)return 0;uint64_t h=hashbytes(CFDataGetBytePtr(d),CFDataGetLength(d));CFRelease(d);return h;}
int main(int argc,char**argv){if(argc<2){fprintf(stderr,"usage: %s converted.dylib [solid|bitmap|ci] [rounds]\n",argv[0]);return 64;}alarm(45);setbuf(stdout,NULL);setbuf(stderr,NULL);@autoreleasepool{
 const char *kind=argc>2?argv[2]:"solid";int iterations=argc>3?atoi(argv[3]):3;
 void*h=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!h){fprintf(stderr,"dlerror %s\n",dlerror());return 2;}Dl_info inf;dladdr((void*)method_getImplementation(class_getInstanceMethod(objc_getClass("Springboard"),sel_registerName("scaleFactorChanged"))),&inf);uintptr_t base=(uintptr_t)inf.dli_fbase;
 CGNative cg=(CGNative)(base+0x1099f);CANative ca=(CANative)(base+0x19204);CACopy cacopy=dlsym(RTLD_DEFAULT,"CARenderImageCopyCGImage");CARelease carelease=dlsym(RTLD_DEFAULT,"CARenderRelease");
 if(!cacopy||!carelease){fprintf(stderr,"missing CARender API\n");return 4;}
 CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);CIContext *ci=[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@NO}];
 CIImage *ciim=[[CIImage imageWithColor:[CIColor colorWithRed:0.3 green:0.7 blue:0.2 alpha:0.8]]imageByCroppingToRect:CGRectMake(0,0,128,128)];
 CGImageRef ciDeferred=[ci createCGImage:ciim fromRect:ciim.extent format:kCIFormatRGBA8 colorSpace:cs deferred:YES];
 CGContextRef source=CGBitmapContextCreate(NULL,128,128,8,512,cs,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);CGContextSetRGBFillColor(source,.3,.7,.2,.8);CGContextFillRect(source,CGRectMake(0,0,128,128));CGImageRef bitmap=CGBitmapContextCreateImage(source);CGContextRelease(source);
 CALayer *layer=[CALayer layer];size_t sizes[]={2,11,128,11,2,128};
 for(int round=0;round<iterations;round++)for(int fmt=0;fmt<3;fmt++)for(int k=0;k<6;k++){@autoreleasepool{size_t n=sizes[k];__block void*data=NULL;__block size_t bpr=0;CGImageRef drawsource=!strcmp(kind,"ci")?ciDeferred:bitmap;
 void(^draw)(CGContextRef)=^(CGContextRef ctx){data=CGBitmapContextGetData(ctx);bpr=CGBitmapContextGetBytesPerRow(ctx);CGContextClearRect(ctx,CGRectMake(0,0,n,n));if(!strcmp(kind,"solid")){CGContextSetRGBFillColor(ctx,.3,.7,.2,.8);CGContextFillRect(ctx,CGRectMake(0,0,n,n));CGContextSetRGBFillColor(ctx,.8,.1,.2,1);CGContextFillEllipseInRect(ctx,CGRectMake(0,0,n*.5,n*.5));}else{CGContextDrawImage(ctx,CGRectMake(0,0,n,n),drawsource);}CGContextFlush(ctx);};
 fprintf(stderr,"before round=%d fmt=%d size=%zu kind=%s\n",round,fmt,n,kind);void*raw=NULL;CGImageRef image=NULL;if(fmt<2){image=(CGImageRef)cg(fmt==1,n,n,54,draw);if(image)CFRetain(image);}else{raw=ca(n,n,54,draw);if(raw&&cacopy)image=cacopy(raw);}
 if(!image){fprintf(stderr,"NULL result fmt=%d raw=%p\n",fmt,raw);return 3;}uint64_t hx=imagehash(image);printprot(data);fprintf(stderr,"w=%zu h=%zu bpr=%zu nativehash=%016llx\n",CGImageGetWidth(image),CGImageGetHeight(image),bpr,(unsigned long long)hx);
 layer.bounds=CGRectMake(0,0,n,n);layer.contents=(id)image;layer.contentsScale=1;[CATransaction flush];CGContextRef out=CGBitmapContextCreate(NULL,n,n,8,n*4,cs,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);[layer renderInContext:out];uint64_t oh=hashbytes(CGBitmapContextGetData(out),n*n*4);CGContextRelease(out);layer.contents=nil;[CATransaction flush];CGImageRelease(image);if(raw&&carelease)carelease(raw);printf("OK %s round=%d fmt=%d %zux%zu raw=%016llx layer=%016llx\n",kind,round,fmt,n,n,(unsigned long long)hx,(unsigned long long)oh);
 }}
 CGImageRelease(bitmap);CGImageRelease(ciDeferred);CGColorSpaceRelease(cs);fprintf(stderr,"done\n");}
 return 0;}

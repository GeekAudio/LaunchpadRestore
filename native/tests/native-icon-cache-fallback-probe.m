// Invoke only the stock cache-completion blocks in a disposable child process.
// No Environment, Launchpad UI, icon services, application DB, or Dock main().
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <unistd.h>

@interface LPRIconCacheFixture : NSObject {
@public
    uint8_t raw[512];
    id storedLarge;
    id storedMini;
    NSUInteger largeSets;
    NSUInteger miniSets;
    NSUInteger forceCalls;
    NSUInteger forcedLarge;
    NSUInteger forcedMini;
    BOOL forced;
}
- (id)iconForStorage;
- (id)miniIconForStorage;
- (void)setIcon:(id)image;
- (void)setMiniIcon:(id)image;
- (void)_retrieveImageOfLargeSize:(NSUInteger)large andMiniSize:(NSUInteger)mini force:(BOOL)force;
@end

@implementation LPRIconCacheFixture
- (id)iconForStorage { return storedLarge; }
- (id)miniIconForStorage { return storedMini; }
- (void)setIcon:(id)image { storedLarge = image; largeSets++; }
- (void)setMiniIcon:(id)image { storedMini = image; miniSets++; }
- (void)_retrieveImageOfLargeSize:(NSUInteger)large andMiniSize:(NSUInteger)mini force:(BOOL)force {
    forceCalls++;
    forcedLarge = large;
    forcedMini = mini;
    forced = force;
}
@end

struct CacheBlock {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    void *descriptor;
    __unsafe_unretained id model;
};
_Static_assert(offsetof(struct CacheBlock, model) == 0x20, "native block capture offset");
typedef void (*CacheCompletion)(struct CacheBlock *, NSUInteger, CGImageRef);

static NSUInteger largeOffset, miniOffset, flagsOffset;
static NSMutableArray *results;

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(3);
    }
}

static uint8_t *Bytes(LPRIconCacheFixture *fixture) {
    return (uint8_t *)(__bridge void *)fixture;
}

static void Sizes(LPRIconCacheFixture *fixture, NSUInteger large, NSUInteger mini) {
    memcpy(Bytes(fixture) + largeOffset, &large, sizeof(large));
    memcpy(Bytes(fixture) + miniOffset, &mini, sizeof(mini));
}

static LPRIconCacheFixture *Fixture(uint8_t flags, id large, id mini) {
    LPRIconCacheFixture *fixture = [LPRIconCacheFixture new];
    Sizes(fixture, 128, 30);
    Bytes(fixture)[flagsOffset] = flags;
    fixture->storedLarge = large;
    fixture->storedMini = mini;
    return fixture;
}

static void Invoke(CacheCompletion callback, LPRIconCacheFixture *fixture,
                   NSUInteger cachedSize, CGImageRef decoded) {
    struct CacheBlock block = {0};
    block.model = fixture;
    callback(&block, cachedSize, decoded);
}

static CGImageRef CreateImage(void) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, 4, 4, 8, 16, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    Check(context != NULL, @"create software fixture bitmap");
    CGContextSetRGBFillColor(context, 0.2, 0.5, 0.8, 1);
    CGContextFillRect(context, CGRectMake(0, 0, 4, 4));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

static void CheckCase(NSString *name, LPRIconCacheFixture *fixture, BOOL mini,
                      id expectedImage, NSUInteger sets, NSUInteger forces,
                      uint8_t expectedFlags) {
    id actualImage = mini ? fixture->storedMini : fixture->storedLarge;
    NSUInteger actualSets = mini ? fixture->miniSets : fixture->largeSets;
    Check(actualImage == expectedImage, [name stringByAppendingString:@": selected image"]);
    Check(actualSets == sets, [name stringByAppendingString:@": setter count"]);
    Check(fixture->forceCalls == forces, [name stringByAppendingString:@": regeneration count"]);
    Check(Bytes(fixture)[flagsOffset] == expectedFlags, [name stringByAppendingString:@": flags"]);
    if (forces) Check(fixture->forced, [name stringByAppendingString:@": force parameter"]);
    [results addObject:@{@"case": name, @"setterCalls": @(actualSets),
        @"forceCalls": @(fixture->forceCalls), @"flags": @(expectedFlags)}];
}

int main(int argc, const char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s converted-stock-Dock.dylib\n", argv[0]);
        return 64;
    }
    alarm(30);
    @autoreleasepool {
        void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            fprintf(stderr, "dlopen: %s\n", dlerror());
            return 2;
        }
        Method anchor = class_getInstanceMethod(objc_getClass("Springboard"),
            sel_registerName("scaleFactorChanged"));
        Dl_info info = {0};
        Check(anchor && dladdr((void *)method_getImplementation(anchor), &info), @"locate native binary");
        uintptr_t base = (uintptr_t)info.dli_fbase;
        CacheCompletion largeCompletion = (CacheCompletion)(base + 0x68eed);
        CacheCompletion miniCompletion = (CacheCompletion)(base + 0x68fc6);
        // Resolve the actual Objective-C ivar-offset variables used by the native
        // blocks. The request-size fields are distinct from the image slots.
        largeOffset = *(NSUInteger *)(base + 0x471430);
        miniOffset = *(NSUInteger *)(base + 0x471440);
        flagsOffset = *(NSUInteger *)(base + 0x471428);
        Check(largeOffset == 0xd0 && miniOffset == 0xd8 && flagsOffset == 0xf8,
            @"expected stock request-size/flag layout");
        Check(ivar_getOffset(class_getInstanceVariable(LPRIconCacheFixture.class, "raw")) == 8,
            @"fixture padding starts after NSObject isa");
        results = [NSMutableArray array];
        CGImageRef oldImage = CreateImage(), decodedImage = CreateImage();
        Check(oldImage && decodedImage, @"create fixture images");
        id old = (__bridge id)oldImage, decoded = (__bridge id)decodedImage;
        for (int kind = 0; kind < 2; kind++) {
            BOOL mini = kind == 1;
            CacheCompletion callback = mini ? miniCompletion : largeCompletion;
            NSUInteger size = mini ? 30 : 128;
            uint8_t loading = mini ? 1 : 4;
            NSString *prefix = mini ? @"mini/" : @"large/";
            LPRIconCacheFixture *fixture;

            fixture = Fixture(loading, nil, nil);
            Invoke(callback, fixture, size, decodedImage);
            CheckCase([prefix stringByAppendingString:@"matching-empty"], fixture, mini, decoded, 1, 0, 0);

            fixture = Fixture(loading, nil, nil);
            Invoke(callback, fixture, size / 2, decodedImage);
            CheckCase([prefix stringByAppendingString:@"mismatched-empty-uses-cache"], fixture, mini, decoded, 1, 0, 0);

            fixture = Fixture(loading, old, old);
            Invoke(callback, fixture, size, decodedImage);
            CheckCase([prefix stringByAppendingString:@"matching-existing-replaces"], fixture, mini, decoded, 1, 0, 0);

            fixture = Fixture(loading, old, old);
            Invoke(callback, fixture, size / 2, decodedImage);
            CheckCase([prefix stringByAppendingString:@"mismatched-existing-regenerates"], fixture, mini, old, 0, 1, 2);
            Check(fixture->forcedLarge == 128 && fixture->forcedMini == 30,
                @"regeneration uses current large and mini requests");

            fixture = Fixture(loading, nil, nil);
            Invoke(callback, fixture, size, NULL);
            CheckCase([prefix stringByAppendingString:@"missing-decoded-regenerates"], fixture, mini, nil, 0, 1, 2);

            fixture = Fixture(loading | 2, old, old);
            Invoke(callback, fixture, size / 2, decodedImage);
            CheckCase([prefix stringByAppendingString:@"regeneration-deduplicated"], fixture, mini, old, 0, 0, 2);

            fixture = Fixture(loading, old, old);
            // Cached callback arrived after a new display scale request.
            Sizes(fixture, 256, 60);
            Invoke(callback, fixture, size, decodedImage);
            CheckCase([prefix stringByAppendingString:@"inflight-size-change"], fixture, mini, old, 0, 1, 2);
            Check(fixture->forcedLarge == 256 && fixture->forcedMini == 60,
                @"inflight callback regenerates latest request sizes");

            fixture = Fixture(0, nil, nil);
            Invoke(callback, fixture, size / 2, decodedImage);
            CheckCase([prefix stringByAppendingString:@"empty-without-loading-still-uses-cache"], fixture, mini, decoded, 1, 0, 0);
        }
        // The single force bit deduplicates large+mini completions for one app.
        LPRIconCacheFixture *both = Fixture(5, old, old);
        Invoke(largeCompletion, both, 64, decodedImage);
        Invoke(miniCompletion, both, 15, decodedImage);
        Check(both->forceCalls == 1 && both->largeSets == 0 && both->miniSets == 0,
            @"large and mini completions share regeneration deduplication");
        Check(Bytes(both)[flagsOffset] == 2, @"both loading bits cleared");
        [results addObject:@{@"case": @"large+mini/shared-regeneration",
            @"forceCalls": @1, @"flags": @2}];
        CGImageRelease(oldImage);
        CGImageRelease(decodedImage);
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{
            @"native": @"stock Dock 2427.6 x86_64", @"cases": results,
            @"largeRequestOffset": @(largeOffset), @"miniRequestOffset": @(miniOffset),
            @"flagsOffset": @(flagsOffset)} options:NSJSONWritingSortedKeys error:NULL];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}

// Exercise the client Core Animation CGContext raster queue without a Dock session.
// The CAEnableMetalWhippet override lives in this process's preference cache only.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef CGContextRef (*CreateSurfaceContext)(IOSurfaceRef, size_t, size_t,
    size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
typedef CGImageRef (*CreateSurfaceImage)(CGContextRef);
typedef void (*ContextOperation)(CGContextRef);

static unsigned long long hashPixels(IOSurfaceRef surface, size_t width)
{
    unsigned long long hash = 1469598103934665603ULL;
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    const unsigned char *pixels = IOSurfaceGetBaseAddress(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    // Exclude row padding. Its contents are not part of the rendered image.
    for (size_t y = 0; y < width; ++y)
        for (size_t x = 0; x < width * 4; ++x)
            hash = (hash ^ pixels[y * bytesPerRow + x]) * 1099511628211ULL;
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    return hash;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        BOOL software = argc > 1 && !strcmp(argv[1], "software");
        int iterations = argc > 2 ? atoi(argv[2]) : 1500;
        if (iterations < 3 || iterations > 100000) {
            fputs("iterations must be between 3 and 100000\n", stderr);
            return 2;
        }
        // The wrapper gives this executable a unique test bundle identifier.
        // Set an in-process app value before the first CGContext draw. Never sync it.
        CFPreferencesSetAppValue(CFSTR("CAEnableMetalWhippet"),
            software ? kCFBooleanFalse : kCFBooleanTrue,
            kCFPreferencesCurrentApplication);
        Boolean exists = false;
        Boolean enabled = CFPreferencesGetAppBooleanValue(
            CFSTR("CAEnableMetalWhippet"), kCFPreferencesCurrentApplication, &exists);
        printf("bundle=%s Whippet=%d exists=%d mode=%s\n",
            NSBundle.mainBundle.bundleIdentifier.UTF8String,
            enabled, exists, software ? "software" : "metal");
        if (!exists || enabled == software)
            return 3;

        // These SPI exports are present in the macOS 26.7.1 x86_64 SDK/runtime.
        // CreateSurfaceContext's fifth size argument is bitsPerPixel, not stride.
        CreateSurfaceContext createContext = dlsym(RTLD_DEFAULT, "CGIOSurfaceContextCreate");
        CreateSurfaceImage createImage = dlsym(RTLD_DEFAULT, "CGIOSurfaceContextCreateImage");
        ContextOperation invalidate = dlsym(RTLD_DEFAULT, "CGIOSurfaceContextInvalidateSurface");
        ContextOperation wait = dlsym(RTLD_DEFAULT, "CGContextWait");
        if (!createContext || !createImage || !invalidate || !wait) {
            fputs("required CoreGraphics SPI is unavailable\n", stderr);
            return 4;
        }

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef source = CGBitmapContextCreate(NULL, 11, 11, 8, 64,
            colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        if (!source)
            return 5;
        CGContextSetRGBFillColor(source, 1, 0, 0, 1);
        CGContextFillRect(source, CGRectMake(0, 0, 11, 11));
        CGImageRef image = CGBitmapContextCreateImage(source);
        unsigned long long hashes[3] = { 0 };
        const size_t sizes[] = { 2, 11, 128 };

        for (int i = 0; i < iterations; ++i) {
            @autoreleasepool {
                size_t width = sizes[i % 3];
                size_t row = (width * 4 + 63) & ~(size_t)63;
                NSDictionary *properties = @{
                    (id)kIOSurfaceWidth: @(width),
                    (id)kIOSurfaceHeight: @(width),
                    (id)kIOSurfaceBytesPerElement: @4,
                    (id)kIOSurfaceBytesPerRow: @(row),
                    (id)kIOSurfaceAllocSize: @(row * width),
                    (id)kIOSurfacePixelFormat: @(0x42475241) // BGRA
                };
                IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
                if (!surface)
                    return 6;
                CGContextRef context = createContext(surface, width, width, 8, 32,
                    colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
                if (!context)
                    return 7;
                CGContextSetShadowWithColor(context, CGSizeMake(1, 1), 2,
                    CGColorGetConstantColor(kCGColorBlack));
                CGContextDrawImage(context, CGRectMake(0, 0, width, width), image);
                CGImageRef output = createImage(context);
                CGContextFlush(context);
                wait(context);
                unsigned long long hash = hashPixels(surface, width);
                if (hashes[i % 3] && hashes[i % 3] != hash) {
                    fprintf(stderr, "pixel hash changed at iteration %d\n", i);
                    return 8;
                }
                hashes[i % 3] = hash;
                if (output)
                    CGImageRelease(output);
                invalidate(context);
                CGContextRelease(context);
                CFRelease(surface);
            }
        }
        CGImageRelease(image);
        CGContextRelease(source);
        CGColorSpaceRelease(colorSpace);
        printf("PIXEL_HASHES {\"2\":\"%016llx\",\"11\":\"%016llx\",\"128\":\"%016llx\"}\n",
            hashes[0], hashes[1], hashes[2]);
        printf("completed iterations=%d\n", iterations);
        return 0;
    }
}

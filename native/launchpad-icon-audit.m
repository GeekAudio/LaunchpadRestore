#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <sqlite3.h>
#include <math.h>
#include <unistd.h>

// A diagnostic only: the database is opened readonly and is never repaired here.
static int Fail(NSString *message) {
    fprintf(stderr, "launchpad-icon-audit: %s\n", message.UTF8String);
    return 1;
}

static NSString *CurrentDatabase(NSError **error) {
    NSTask *task = [[NSTask alloc] init];
    NSPipe *output = [NSPipe pipe];
    NSPipe *errors = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/getconf"];
    task.arguments = @[@"DARWIN_USER_DIR"];
    task.standardOutput = output;
    task.standardError = errors;
    if (![task launchAndReturnError:error]) return nil;
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        if (error) *error = [NSError errorWithDomain:@"launchpad-icon-audit" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"getconf DARWIN_USER_DIR failed"}];
        return nil;
    }
    NSString *directory = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![directory isAbsolutePath]) {
        if (error) *error = [NSError errorWithDomain:@"launchpad-icon-audit" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"getconf did not return an absolute directory"}];
        return nil;
    }
    return [directory stringByAppendingPathComponent:@"com.apple.dock.launchpad/db/db"];
}

static NSDictionary *InspectImage(sqlite3_stmt *statement, int column) {
    int length = sqlite3_column_bytes(statement, column);
    NSMutableDictionary *result = [@{@"byteLength": @(length), @"width": @0,
        @"height": @0, @"alphaNonzeroCount": @0, @"maxAlpha": @0} mutableCopy];
    if (sqlite3_column_type(statement, column) == SQLITE_NULL || length == 0) {
        result[@"status"] = @"missing";
        return result;
    }
    const void *bytes = sqlite3_column_blob(statement, column);
    NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0,
        (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache: @NO}) : NULL;
    if (source) {
        CFStringRef type = CGImageSourceGetType(source);
        if (type) result[@"encoding"] = (__bridge NSString *)type;
        CFRelease(source);
    }
    if (!image) {
        result[@"status"] = @"undecodable";
        result[@"reason"] = @"ImageIO could not decode the image";
        return result;
    }
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    result[@"width"] = @(width);
    result[@"height"] = @(height);
    // Bound allocations even if a corrupt cache contains an enormous image.
    if (!width || !height || width > 4096 || height > 4096) {
        result[@"status"] = @"undecodable";
        result[@"reason"] = @"invalid dimensions or larger than the 4096-pixel audit limit";
        CGImageRelease(image);
        return result;
    }
    // Float pixels preserve low but nonzero alpha in 16-bit cache PNGs. Drawing
    // into caller-owned bitmap memory avoids a layer/IOSurface/Metal context.
    size_t rowBytes = width * 4 * sizeof(float);
    float *pixels = calloc(height, rowBytes);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    CGContextRef context = pixels && colorSpace ? CGBitmapContextCreate(pixels, width, height,
        32, rowBytes, colorSpace, kCGImageAlphaPremultipliedLast |
        kCGBitmapFloatComponents | kCGBitmapByteOrder32Host) : NULL;
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    if (!context) {
        free(pixels);
        CGImageRelease(image);
        result[@"status"] = @"undecodable";
        result[@"reason"] = @"could not create a software bitmap context";
        return result;
    }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextFlush(context);
    uint64_t nonzero = 0;
    float maximum = 0;
    for (size_t index = 0; index < width * height; index++) {
        float alpha = pixels[index * 4 + 3];
        if (isfinite(alpha) && alpha > 0) {
            nonzero++;
            if (alpha > maximum) maximum = alpha;
        }
    }
    CGContextRelease(context);
    CGImageRelease(image);
    free(pixels);
    result[@"alphaNonzeroCount"] = @(nonzero);
    result[@"maxAlpha"] = @(maximum);
    result[@"status"] = nonzero ? @"ok" : @"transparent";
    return result;
}

static id TextColumn(sqlite3_stmt *statement, int column) {
    const unsigned char *text = sqlite3_column_text(statement, column);
    return text ? [NSString stringWithUTF8String:(const char *)text] ?: (id)NSNull.null : NSNull.null;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL all = NO;
        NSString *path = nil;
        for (int index = 1; index < argc; index++) {
            NSString *argument = @(argv[index]);
            if ([argument isEqualToString:@"--all"]) all = YES;
            else if ([argument isEqualToString:@"--db"] && index + 1 < argc && !path)
                path = @(argv[++index]);
            else if ([argument isEqualToString:@"--help"]) {
                puts("Usage: launchpad-icon-audit [--all] [--db PATH]\n"
                     "Readonly JSON audit. Default: current user's Launchpad cache.\n"
                     "Without --all, entries contains only missing, undecodable, or transparent icons.");
                return 0;
            } else return Fail(@"usage: launchpad-icon-audit [--all] [--db PATH]");
        }
        NSError *error = nil;
        if (!path) {
            if (getuid() == 0 || geteuid() == 0) return Fail(@"default user lookup is refused as root; use --db for an explicit fixture");
            path = CurrentDatabase(&error);
            if (!path) return Fail(error.localizedDescription ?: @"could not locate the current user's cache");
        }
        path = path.stringByStandardizingPath;
        sqlite3 *database = NULL;
        int code = sqlite3_open_v2(path.fileSystemRepresentation, &database, SQLITE_OPEN_READONLY, NULL);
        if (code != SQLITE_OK) {
            NSString *message = [NSString stringWithFormat:@"open %@: %s", path,
                database ? sqlite3_errmsg(database) : "could not allocate SQLite handle"];
            if (database) sqlite3_close(database);
            return Fail(message);
        }
        sqlite3_busy_timeout(database, 3000);
        if (sqlite3_db_readonly(database, "main") != 1 ||
            sqlite3_exec(database, "BEGIN", NULL, NULL, NULL) != SQLITE_OK) {
            NSString *message = @(sqlite3_errmsg(database));
            sqlite3_close(database);
            return Fail(message);
        }
        const char *query = "SELECT a.item_id,a.title,a.bundleid,i.rowid,i.size_big,i.size_mini,"
            "i.image_data,i.image_data_mini FROM apps AS a LEFT JOIN image_cache AS i "
            "ON i.item_id=a.item_id ORDER BY a.item_id,i.rowid";
        sqlite3_stmt *statement = NULL;
        code = sqlite3_prepare_v2(database, query, -1, &statement, NULL);
        if (code != SQLITE_OK) {
            NSString *message = @(sqlite3_errmsg(database));
            sqlite3_exec(database, "ROLLBACK", NULL, NULL, NULL);
            sqlite3_close(database);
            return Fail(message);
        }
        NSMutableArray *entries = [NSMutableArray array];
        NSMutableSet *apps = [NSMutableSet set];
        NSMutableSet *affectedApps = [NSMutableSet set];
        NSMutableDictionary *imageCounts = [@{@"ok": @0, @"missing": @0,
            @"undecodable": @0, @"transparent": @0} mutableCopy];
        NSUInteger rows = 0, cacheEntries = 0;
        while ((code = sqlite3_step(statement)) == SQLITE_ROW) {
            @autoreleasepool {
                NSNumber *itemID = @(sqlite3_column_int64(statement, 0));
                [apps addObject:itemID];
                rows++;
                BOOL present = sqlite3_column_type(statement, 3) != SQLITE_NULL;
                if (present) cacheEntries++;
                NSDictionary *big = InspectImage(statement, 6);
                NSDictionary *mini = InspectImage(statement, 7);
                for (NSDictionary *image in @[big, mini]) {
                    NSString *status = image[@"status"];
                    imageCounts[status] = @([imageCounts[status] unsignedIntegerValue] + 1);
                }
                BOOL affected = ![big[@"status"] isEqual:@"ok"] || ![mini[@"status"] isEqual:@"ok"];
                if (affected) [affectedApps addObject:itemID];
                if (all || affected) [entries addObject:@{
                    @"itemID": itemID, @"title": TextColumn(statement, 1),
                    @"bundleid": TextColumn(statement, 2),
                    @"cacheRowID": present ? @(sqlite3_column_int64(statement, 3)) : (id)NSNull.null,
                    @"sizeBig": present ? @(sqlite3_column_int64(statement, 4)) : (id)NSNull.null,
                    @"sizeMini": present ? @(sqlite3_column_int64(statement, 5)) : (id)NSNull.null,
                    @"big": big, @"mini": mini}];
            }
        }
        NSString *failure = code == SQLITE_DONE ? nil : @(sqlite3_errmsg(database));
        sqlite3_finalize(statement);
        if (sqlite3_exec(database, "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK && !failure)
            failure = @(sqlite3_errmsg(database));
        sqlite3_close(database);
        if (failure) return Fail(failure);
        NSDictionary *report = @{@"database": path, @"readonly": @YES,
            @"allEntries": @(all), @"counts": @{@"apps": @(apps.count),
                @"rows": @(rows), @"cacheEntries": @(cacheEntries),
                @"affectedApps": @(affectedApps.count), @"images": imageCounts},
            @"entries": entries};
        NSData *json = [NSJSONSerialization dataWithJSONObject:report
            options:NSJSONWritingSortedKeys error:&error];
        if (!json) return Fail(error.localizedDescription);
        if (fwrite(json.bytes, 1, json.length, stdout) != json.length || fputc('\n', stdout) == EOF)
            return Fail(@"could not write JSON output");
        return 0;
    }
}

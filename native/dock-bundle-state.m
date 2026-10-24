#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <IOKit/IOKitLib.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <unistd.h>

// This tool inventories bundles and binds a backup to its originating machine.
// Only --create writes, and it only creates the explicitly named manifest.
static BOOL Fail(NSString *message) {
    fprintf(stderr, "dock-bundle-state: %s\n", message.UTF8String);
    return NO;
}

static BOOL FailErrno(NSString *operation) {
    return Fail([NSString stringWithFormat:@"%@: %s", operation, strerror(errno)]);
}

static BOOL PrintJSON(NSDictionary *object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
        options:NSJSONWritingSortedKeys error:&error];
    if (!data) return Fail(error.localizedDescription);
    if (fwrite(data.bytes, 1, data.length, stdout) != data.length || fputc('\n', stdout) == EOF)
        return Fail(@"could not write JSON output");
    return YES;
}

static BOOL NonemptyString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0;
}

static BOOL ContainsNUL(NSString *value) {
    return [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)]].location
        != NSNotFound;
}

static BOOL RelativePath(NSString *path) {
    if (!NonemptyString(path) || path.isAbsolutePath || [path hasSuffix:@"/"] || ContainsNUL(path)) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"])
        if (part.length == 0 || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    return YES;
}

static NSArray<NSString *> *AbsoluteComponents(NSString *path) {
    if (!NonemptyString(path) || !path.isAbsolutePath || ContainsNUL(path)) {
        Fail(@"paths must be absolute and contain no NUL characters");
        return nil;
    }
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (part.length == 0) continue;
        if ([part isEqual:@"."] || [part isEqual:@".."]) {
            Fail(@"path components '.' and '..' are not accepted");
            return nil;
        }
        [result addObject:part];
    }
    if (result.count == 0) { Fail(@"a filesystem root is not a bundle or manifest"); return nil; }
    return result;
}

static BOOL SameFile(struct stat a, struct stat b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
        a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
        a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec &&
        a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
}

// Walk each path component with O_NOFOLLOW, including the bundle/manifest parent.
static int OpenDirectoryComponents(NSArray<NSString *> *parts, BOOL protectedParents) {
    int descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) { FailErrno(@"open filesystem root"); return -1; }
    for (NSString *part in parts) {
        int next = openat(descriptor, part.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) { FailErrno(@"open directory without following symlinks"); close(descriptor); return -1; }
        close(descriptor);
        descriptor = next;
        if (protectedParents) {
            struct stat st;
            if (fstat(descriptor, &st) != 0) {
                FailErrno(@"inspect manifest directory"); close(descriptor); return -1;
            }
            if (st.st_uid != 0 || (st.st_mode & 0022) != 0) {
                Fail(@"manifest directories must be root-owned and not writable by group or others");
                close(descriptor); return -1;
            }
        }
    }
    return descriptor;
}

static int OpenBundle(NSString *path) {
    NSArray *parts = AbsoluteComponents(path);
    if (!parts) return -1;
    return OpenDirectoryComponents(parts, NO);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSString *HashFile(int directory, const char *name, struct stat expected) {
    int descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) { FailErrno(@"open bundle file"); return nil; }
    struct stat before, after;
    if (fstat(descriptor, &before) != 0 || !S_ISREG(before.st_mode) || !SameFile(before, expected)) {
        Fail(@"bundle file changed during inventory"); close(descriptor); return nil;
    }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[65536];
    for (;;) {
        ssize_t count = read(descriptor, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { FailErrno(@"read bundle file"); close(descriptor); return nil; }
        if (count == 0) break;
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    if (fstat(descriptor, &after) != 0 || !SameFile(before, after)) {
        Fail(@"bundle file changed while hashing"); close(descriptor); return nil;
    }
    close(descriptor);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++)
        snprintf(hex + index * 2, 3, "%02x", digest[index]);
    return [NSString stringWithUTF8String:hex];
}
#pragma clang diagnostic pop

static BOOL WalkBundle(int directory, NSString *relative, NSMutableDictionary *files,
                       NSMutableDictionary *symlinks, NSMutableArray *directories) {
    if (relative.length >= PATH_MAX || (relative.length && relative.pathComponents.count > 128))
        return Fail(@"bundle directory nesting or path length exceeds inventory limits");
    struct stat before, after;
    if (fstat(directory, &before) != 0) return FailErrno(@"inspect bundle directory");
    int copy = dup(directory);
    if (copy < 0) return FailErrno(@"duplicate bundle directory");
    DIR *stream = fdopendir(copy);
    if (!stream) { close(copy); return FailErrno(@"read bundle directory"); }
    BOOL ok = YES;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(stream);
        if (!entry) { if (errno != 0) ok = FailErrno(@"enumerate bundle directory"); break; }
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if (!name) { ok = Fail(@"bundle contains a non-UTF-8 filename"); break; }
        NSString *path = relative.length ? [relative stringByAppendingFormat:@"/%@", name] : name;
        if (files.count + symlinks.count + directories.count >= 200000) {
            ok = Fail(@"bundle inventory exceeds 200000 entries"); break;
        }
        struct stat st;
        if (fstatat(directory, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
            ok = FailErrno(@"inspect bundle entry"); break;
        }
        if (S_ISREG(st.st_mode)) {
            NSString *digest = HashFile(directory, entry->d_name, st);
            if (!digest) { ok = NO; break; }
            files[path] = digest;
        } else if (S_ISDIR(st.st_mode)) {
            int child = openat(directory, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            struct stat opened;
            if (child < 0) { ok = FailErrno(@"open child bundle directory"); break; }
            if (fstat(child, &opened) != 0 || !SameFile(st, opened))
                ok = Fail(@"bundle directory changed during inventory");
            if (ok) {
                [directories addObject:path];
                ok = WalkBundle(child, path, files, symlinks, directories);
            }
            close(child);
            if (!ok) break;
        } else if (S_ISLNK(st.st_mode)) {
            char target[65537];
            ssize_t count = readlinkat(directory, entry->d_name, target, sizeof(target) - 1);
            if (count < 0) { ok = FailErrno(@"read bundle symlink"); break; }
            if (count == 0 || count >= (ssize_t)sizeof(target) - 1) {
                ok = Fail(@"bundle symlink target is empty or too long"); break;
            }
            NSString *value = [[NSString alloc] initWithBytes:target length:(NSUInteger)count
                encoding:NSUTF8StringEncoding];
            if (!value || fstatat(directory, entry->d_name, &after, AT_SYMLINK_NOFOLLOW) != 0 ||
                !SameFile(st, after)) { ok = Fail(@"bundle symlink changed or is not UTF-8"); break; }
            symlinks[path] = value;
        } else {
            ok = Fail([NSString stringWithFormat:@"unsupported filesystem object in bundle: %@", path]);
            break;
        }
    }
    closedir(stream);
    if (ok && (fstat(directory, &after) != 0 || !SameFile(before, after)))
        ok = Fail(@"bundle directory changed during inventory");
    return ok;
}

static NSData *ReadDescriptor(int descriptor, NSUInteger limit) {
    struct stat before, after;
    if (fstat(descriptor, &before) != 0 || !S_ISREG(before.st_mode) ||
        before.st_size <= 0 || (uint64_t)before.st_size > limit) {
        Fail(@"input must be a regular file with a valid size"); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)before.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = read(descriptor, (char *)data.mutableBytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { Fail(@"input file could not be read completely"); return nil; }
        offset += (NSUInteger)count;
    }
    if (fstat(descriptor, &after) != 0 || !SameFile(before, after)) {
        Fail(@"input file changed while reading"); return nil;
    }
    return data;
}

static NSDictionary *Inventory(NSString *bundle) {
    int root = OpenBundle(bundle);
    if (root < 0) return nil;
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    NSMutableDictionary *symlinks = [NSMutableDictionary dictionary];
    NSMutableArray *directories = [NSMutableArray array];
    if (!WalkBundle(root, @"", files, symlinks, directories)) { close(root); return nil; }
    NSString *exeHash = files[@"Contents/MacOS/Dock"];
    NSString *infoHash = files[@"Contents/Info.plist"];
    if (!exeHash || !infoHash) {
        Fail(@"bundle is missing regular Contents/MacOS/Dock or Contents/Info.plist files");
        close(root); return nil;
    }
    int contents = openat(root, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int info = contents < 0 ? -1 : openat(contents, "Info.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    NSData *data = info < 0 ? nil : ReadDescriptor(info, 1024 * 1024);
    if (info >= 0) close(info);
    if (contents >= 0) close(contents);
    close(root);
    if (!data) { Fail(@"could not securely read Dock Info.plist"); return nil; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *readHash = [NSMutableString string];
    for (NSUInteger index = 0; index < sizeof(digest); index++) [readHash appendFormat:@"%02x", digest[index]];
    if (![readHash isEqual:infoHash]) { Fail(@"Dock Info.plist changed after inventory"); return nil; }
    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:&error];
    if (![plist isKindOfClass:NSDictionary.class] ||
        ![plist[@"CFBundleIdentifier"] isEqual:@"com.apple.dock"] ||
        !NonemptyString(plist[@"CFBundleVersion"])) {
        Fail(@"bundle Info.plist is not a versioned com.apple.dock bundle"); return nil;
    }
    [directories sortUsingSelector:@selector(compare:)];
    return @{ @"DockBundleVersion": plist[@"CFBundleVersion"],
        @"DockExecutableSHA256": exeHash, @"DockInfoPlistSHA256": infoHash,
        @"BundleFiles": files, @"BundleSymlinks": symlinks, @"BundleDirectories": directories };
}

static NSData *Run(NSString *program, NSArray *arguments) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:program];
    task.arguments = arguments;
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = NSFileHandle.fileHandleWithStandardError;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { Fail(error.localizedDescription); return nil; }
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationReason != NSTaskTerminationReasonExit || task.terminationStatus != 0) {
        Fail([NSString stringWithFormat:@"%@ failed", program]); return nil;
    }
    return data;
}

static NSString *RunString(NSString *program, NSArray *arguments) {
    NSData *data = Run(program, arguments);
    if (!data) return nil;
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *UUIDString(id value) {
    if (!NonemptyString(value)) return nil;
    return [[NSUUID alloc] initWithUUIDString:value].UUIDString;
}

static NSDictionary *MachineMetadata(void) {
    NSString *product = RunString(@"/usr/bin/sw_vers", @[@"-productVersion"]);
    NSString *build = RunString(@"/usr/bin/sw_vers", @[@"-buildVersion"]);
    struct utsname uts;
    if (uname(&uts) != 0) { FailErrno(@"read machine architecture"); return nil; }
    NSString *architecture = [NSString stringWithUTF8String:uts.machine];
    NSData *diskData = Run(@"/usr/sbin/diskutil", @[@"info", @"-plist", @"/"]);
    id disk = diskData ? [NSPropertyListSerialization propertyListWithData:diskData
        options:NSPropertyListImmutable format:NULL error:NULL] : nil;
    NSString *volume = [disk isKindOfClass:NSDictionary.class] ? UUIDString(disk[@"APFSVolumeGroupID"]) : nil;
    io_service_t platform = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("IOPlatformExpertDevice"));
    NSString *hardware = nil;
    if (platform) {
        id value = CFBridgingRelease(IORegistryEntryCreateCFProperty(platform,
            CFSTR("IOPlatformUUID"), kCFAllocatorDefault, 0));
        hardware = UUIDString(value);
        IOObjectRelease(platform);
    }
    if (!NonemptyString(product) || !NonemptyString(build) || !NonemptyString(architecture) ||
        !volume || !hardware) {
        Fail(@"could not obtain complete OS, APFS volume-group, and hardware metadata"); return nil;
    }
    return @{ @"FormatVersion": @1, @"OSProductVersion": product, @"OSBuildVersion": build,
        @"Architecture": architecture, @"APFSVolumeGroupUUID": volume, @"HardwareUUID": hardware };
}

static BOOL SHA256String(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 64) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    return [value rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

static NSArray *InventoryKeys(void) {
    return @[@"DockBundleVersion", @"DockExecutableSHA256", @"DockInfoPlistSHA256",
        @"BundleFiles", @"BundleSymlinks", @"BundleDirectories"];
}

static BOOL ValidateInventory(id manifest) {
    if (![manifest isKindOfClass:NSDictionary.class] ||
        ![[NSSet setWithArray:[manifest allKeys]] isEqual:[NSSet setWithArray:InventoryKeys()]] ||
        !NonemptyString(manifest[@"DockBundleVersion"]) ||
        !SHA256String(manifest[@"DockExecutableSHA256"]) || !SHA256String(manifest[@"DockInfoPlistSHA256"]) ||
        ![manifest[@"BundleFiles"] isKindOfClass:NSDictionary.class] ||
        ![manifest[@"BundleSymlinks"] isKindOfClass:NSDictionary.class] ||
        ![manifest[@"BundleDirectories"] isKindOfClass:NSArray.class])
        return Fail(@"bundle inventory keys, digest, or types are invalid");
    NSMutableSet *paths = [NSMutableSet set];
    for (NSString *key in @[@"BundleFiles", @"BundleSymlinks"])
        for (id path in manifest[key]) {
            id value = manifest[key][path];
            if (![path isKindOfClass:NSString.class] || !RelativePath(path) || [paths containsObject:path] ||
                ([key isEqual:@"BundleFiles"] ? !SHA256String(value) : !NonemptyString(value)))
                return Fail(@"manifest contains invalid or duplicate inventory paths");
            [paths addObject:path];
        }
    for (id path in manifest[@"BundleDirectories"]) {
        if (![path isKindOfClass:NSString.class] || !RelativePath(path) || [paths containsObject:path])
            return Fail(@"manifest contains invalid or duplicate directory paths");
        [paths addObject:path];
    }
    if (![manifest[@"DockExecutableSHA256"] isEqual:manifest[@"BundleFiles"][@"Contents/MacOS/Dock"]] ||
        ![manifest[@"DockInfoPlistSHA256"] isEqual:manifest[@"BundleFiles"][@"Contents/Info.plist"]])
        return Fail(@"manifest Dock metadata does not match its file inventory");
    return YES;
}

static BOOL ValidateManifest(id manifest) {
    NSMutableArray *keys = [InventoryKeys() mutableCopy];
    [keys addObjectsFromArray:@[@"FormatVersion", @"OSProductVersion", @"OSBuildVersion", @"Architecture",
        @"APFSVolumeGroupUUID", @"HardwareUUID"]];
    if (![manifest isKindOfClass:NSDictionary.class] ||
        ![[NSSet setWithArray:[manifest allKeys]] isEqual:[NSSet setWithArray:keys]] ||
        ![manifest[@"FormatVersion"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)manifest[@"FormatVersion"]) == CFBooleanGetTypeID() ||
        ![manifest[@"FormatVersion"] isEqual:@1]) return Fail(@"backup manifest format is invalid");
    for (NSString *key in @[@"OSProductVersion", @"OSBuildVersion", @"Architecture"])
        if (!NonemptyString(manifest[key])) return Fail(@"backup manifest metadata is incomplete");
    if (!UUIDString(manifest[@"APFSVolumeGroupUUID"]) || !UUIDString(manifest[@"HardwareUUID"]))
        return Fail(@"backup manifest UUIDs are invalid");
    return ValidateInventory([manifest dictionaryWithValuesForKeys:InventoryKeys()]);
}

static NSDictionary *ReadManifest(NSString *path, BOOL bundleOnly) {
    NSArray *parts = AbsoluteComponents(path);
    if (!parts) return nil;
    int parent = OpenDirectoryComponents([parts subarrayWithRange:NSMakeRange(0, parts.count - 1)], NO);
    if (parent < 0) return nil;
    int descriptor = openat(parent, [parts.lastObject fileSystemRepresentation], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    close(parent);
    if (descriptor < 0) { FailErrno(@"open manifest without following symlinks"); return nil; }
    struct stat st;
    if (fstat(descriptor, &st) != 0 || !S_ISREG(st.st_mode)) {
        Fail(@"manifest must be a regular file"); close(descriptor); return nil;
    }
    if (bundleOnly) {
        if ((st.st_uid != 0 && st.st_uid != geteuid()) || (st.st_mode & 0022) != 0) {
            Fail(@"bundle inventory must be owned by root or the current user and not writable by group or others");
            close(descriptor); return nil;
        }
    } else if (st.st_uid != 0 || (st.st_mode & 07777) != 0600) {
        Fail(@"backup manifest must be root-owned with permissions 0600"); close(descriptor); return nil;
    }
    NSData *data = ReadDescriptor(descriptor, 32 * 1024 * 1024);
    close(descriptor);
    if (!data) return nil;
    NSError *error = nil;
    id manifest = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:&error];
    if (!manifest) { Fail(error.localizedDescription); return nil; }
    BOOL valid;
    if (bundleOnly && [manifest isKindOfClass:NSDictionary.class] && [manifest count] == InventoryKeys().count)
        valid = ValidateInventory(manifest);
    else
        valid = ValidateManifest(manifest);
    return valid ? manifest : nil;
}

static BOOL CreateManifest(NSString *path, NSDictionary *manifest) {
    if (geteuid() != 0) return Fail(@"manifest creation must run as root");
    NSArray *parts = AbsoluteComponents(path);
    if (!parts) return NO;
    int parent = OpenDirectoryComponents([parts subarrayWithRange:NSMakeRange(0, parts.count - 1)], YES);
    if (parent < 0) return NO;
    NSString *name = parts.lastObject;
    struct stat existing;
    if (fstatat(parent, name.fileSystemRepresentation, &existing, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) {
        Fail(@"manifest path already exists or cannot be inspected; it will not be replaced"); close(parent); return NO;
    }
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:manifest
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!data) { Fail(error.localizedDescription); close(parent); return NO; }
    NSString *temporary = [NSString stringWithFormat:@".dock-bundle-state-%@.tmp", NSUUID.UUID.UUIDString];
    int descriptor = openat(parent, temporary.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor < 0) { FailErrno(@"create temporary manifest"); close(parent); return NO; }
    BOOL ok = fchmod(descriptor, 0600) == 0;
    if (!ok) FailErrno(@"set manifest permissions");
    NSUInteger offset = 0;
    while (ok && offset < data.length) {
        ssize_t count = write(descriptor, (const char *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = FailErrno(@"write manifest"); break; }
        offset += (NSUInteger)count;
    }
    if (ok && fsync(descriptor) != 0) ok = FailErrno(@"sync manifest");
    if (close(descriptor) != 0 && ok) ok = FailErrno(@"close manifest");
    // Publish atomically while refusing to replace a concurrent file or symlink.
    if (ok && linkat(parent, temporary.fileSystemRepresentation, parent, name.fileSystemRepresentation, 0) != 0)
        ok = FailErrno(@"publish new manifest without replacing an existing path");
    if (unlinkat(parent, temporary.fileSystemRepresentation, 0) != 0 && ok)
        ok = FailErrno(@"remove temporary manifest");
    if (ok && fsync(parent) != 0) ok = FailErrno(@"sync manifest directory");
    close(parent);
    return ok;
}

static NSDictionary *Header(NSDictionary *manifest, NSString *operation) {
    NSMutableDictionary *header = [NSMutableDictionary dictionaryWithDictionary:@{
        @"ok": @YES, @"operation": operation,
        @"fileCount": @([manifest[@"BundleFiles"] count]),
        @"symlinkCount": @([manifest[@"BundleSymlinks"] count]),
        @"directoryCount": @([manifest[@"BundleDirectories"] count]) }];
    for (NSString *key in manifest)
        if (![key hasPrefix:@"Bundle"]) header[key] = manifest[key];
    return header;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *operation = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : nil;
        BOOL inventoryOnly = [operation isEqual:@"--inventory"];
        BOOL create = [operation isEqual:@"--create"];
        BOOL verify = [operation isEqual:@"--verify"];
        BOOL verifyBundle = [operation isEqual:@"--verify-bundle"];
        if ((inventoryOnly && argc != 3) || (!(create || verify || verifyBundle || inventoryOnly)) ||
            (!inventoryOnly && argc != 4)) {
            fprintf(stderr, "usage: dock-bundle-state --inventory BUNDLE\n"
                "       dock-bundle-state --create BUNDLE MANIFEST\n"
                "       dock-bundle-state --verify BUNDLE MANIFEST\n"
                "       dock-bundle-state --verify-bundle BUNDLE MANIFEST\n");
            return 2;
        }
        NSString *bundle = [NSString stringWithUTF8String:argv[2]];
        NSDictionary *inventory = Inventory(bundle);
        if (!inventory) return 1;
        if (inventoryOnly) return PrintJSON(inventory) ? 0 : 1;
        NSString *path = [NSString stringWithUTF8String:argv[3]];
        if (create) {
            NSDictionary *machine = MachineMetadata();
            if (!machine) return 1;
            NSMutableDictionary *manifest = [machine mutableCopy];
            [manifest addEntriesFromDictionary:inventory];
            if (!ValidateManifest(manifest) || !CreateManifest(path, manifest)) return 1;
            return PrintJSON(Header(manifest, @"create")) ? 0 : 1;
        }
        NSDictionary *manifest = ReadManifest(path, verifyBundle);
        if (!manifest) return 1;
        for (NSString *key in inventory)
            if (![inventory[key] isEqual:manifest[key]]) {
                Fail([NSString stringWithFormat:@"bundle inventory mismatch: %@", key]); return 1;
            }
        if (verify) {
            NSDictionary *machine = MachineMetadata();
            if (!machine) return 1;
            for (NSString *key in machine)
                if (![machine[key] isEqual:manifest[key]]) {
                    Fail([NSString stringWithFormat:@"backup machine metadata mismatch: %@", key]); return 1;
                }
        }
        return PrintJSON(Header(manifest, verify ? @"verify" : @"verify-bundle")) ? 0 : 1;
    }
}

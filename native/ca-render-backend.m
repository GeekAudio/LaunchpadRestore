#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

// Keep the preference scoped to Dock. The alternate domain is for isolated tests.
static NSString *const PreferenceKey = @"CAEnableMetalWhippet";
static NSString *const DockDomain = @"com.apple.dock";
static const NSInteger StateVersion = 1;

static BOOL Fail(NSString *message) {
    fprintf(stderr, "ca-render-backend: %s\n", message.UTF8String);
    return NO;
}

static BOOL FailErrno(NSString *operation) {
    return Fail([NSString stringWithFormat:@"%@: %s", operation, strerror(errno)]);
}

static id CopyPreference(NSString *domain, CFStringRef host) {
    return CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)PreferenceKey,
        (__bridge CFStringRef)domain, kCFPreferencesCurrentUser, host));
}

static id CopyEffective(NSString *domain) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)PreferenceKey,
        (__bridge CFStringRef)domain));
}

static NSDictionary *StoredValue(id value) {
    return value ? @{ @"present": @YES, @"value": value } : @{ @"present": @NO };
}

static BOOL IsBoolean(id value) {
    return value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL IsFalse(id value) {
    return IsBoolean(value) && ![value boolValue];
}

static id JSONValue(id value) {
    if (!value) return [NSNull null];
    if ([NSJSONSerialization isValidJSONObject:@[value]]) return value;
    return @{ @"description": [value description] };
}

static NSDictionary *StatusValue(id value) {
    return value ? @{ @"present": @YES, @"value": JSONValue(value) }
                 : @{ @"present": @NO, @"value": [NSNull null] };
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

static NSDictionary *Status(NSString *domain) {
    return @{ @"domain": domain, @"key": PreferenceKey,
        @"effective": JSONValue(CopyEffective(domain)),
        @"scopes": @{ @"anyHost": StatusValue(CopyPreference(domain, kCFPreferencesAnyHost)),
                      @"currentHost": StatusValue(CopyPreference(domain, kCFPreferencesCurrentHost)) } };
}

static BOOL ValidateScope(id scope) {
    if (![scope isKindOfClass:[NSDictionary class]] || !IsBoolean(scope[@"present"])) return NO;
    return [scope[@"present"] boolValue] ? scope[@"value"] != nil : scope[@"value"] == nil;
}

static BOOL ValidateState(NSDictionary *state, NSString *domain) {
    if (![state isKindOfClass:[NSDictionary class]] ||
        ![state[@"version"] isEqual:@(StateVersion)] ||
        ![state[@"uid"] isEqual:@(getuid())] ||
        ![state[@"app"] isEqual:domain] ||
        ![state[@"key"] isEqual:PreferenceKey] ||
        !ValidateScope(state[@"anyHost"]) || !ValidateScope(state[@"currentHost"]))
        return Fail(@"backup is invalid or belongs to a different user, domain, or version");
    return YES;
}

// Use a directory descriptor so atomic creation and removal stay in the checked directory.
static int OpenStateDirectory(NSString *path, BOOL create) {
    NSString *parent = path.stringByDeletingLastPathComponent;
    if (create) {
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:parent
                withIntermediateDirectories:YES attributes:@{ NSFilePosixPermissions: @0700 }
                error:&error]) {
            Fail(error.localizedDescription);
            return -1;
        }
    }
    int descriptor = open(parent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (descriptor < 0) { FailErrno(@"open backup directory"); return -1; }
    struct stat st;
    if (fstat(descriptor, &st) != 0) {
        FailErrno(@"inspect backup directory"); close(descriptor); return -1;
    }
    if (!S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 0777) != 0700) {
        Fail(@"backup directory must be owned by the current user with permissions 0700");
        close(descriptor);
        return -1;
    }
    return descriptor;
}

static NSDictionary *ReadState(int directory, NSString *name, NSString *domain, BOOL *missing) {
    *missing = NO;
    int descriptor = openat(directory, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (descriptor < 0) {
        if (errno == ENOENT) *missing = YES;
        else FailErrno(@"open backup");
        return nil;
    }
    struct stat st;
    if (fstat(descriptor, &st) != 0) {
        FailErrno(@"inspect backup"); close(descriptor); return nil;
    }
    if (!S_ISREG(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 0777) != 0600 ||
        st.st_size <= 0 || st.st_size > 1024 * 1024) {
        Fail(@"backup must be an owned regular file with permissions 0600 and a valid size");
        close(descriptor); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t count = read(descriptor, (char *)data.mutableBytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            Fail(@"could not read complete backup"); close(descriptor); return nil;
        }
        offset += (size_t)count;
    }
    close(descriptor);
    NSError *error = nil;
    id state = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:&error];
    if (!state) { Fail(error.localizedDescription); return nil; }
    return ValidateState(state, domain) ? state : nil;
}

static BOOL CreateState(int directory, NSString *name, NSDictionary *state) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:state
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!data) return Fail(error.localizedDescription);
    NSString *temporary = [NSString stringWithFormat:@".%@.%@.tmp", name, NSUUID.UUID.UUIDString];
    int descriptor = openat(directory, temporary.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (descriptor < 0) return FailErrno(@"create temporary backup");
    BOOL ok = YES;
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t count = write(descriptor, (const char *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = FailErrno(@"write backup"); break; }
        offset += (size_t)count;
    }
    if (ok && fsync(descriptor) != 0) ok = FailErrno(@"sync backup");
    if (close(descriptor) != 0 && ok) ok = FailErrno(@"close backup");
    // linkat is atomic and refuses to replace any backup created in the meantime.
    if (ok && linkat(directory, temporary.fileSystemRepresentation,
                    directory, name.fileSystemRepresentation, 0) != 0)
        ok = FailErrno(@"publish backup without replacing an existing file");
    if (unlinkat(directory, temporary.fileSystemRepresentation, 0) != 0 && ok)
        ok = FailErrno(@"remove temporary backup");
    if (ok && fsync(directory) != 0) ok = FailErrno(@"sync backup directory");
    return ok;
}

static BOOL Synchronize(NSString *domain) {
    BOOL any = CFPreferencesSynchronize((__bridge CFStringRef)domain,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    BOOL host = CFPreferencesSynchronize((__bridge CFStringRef)domain,
        kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    if (!any || !host) return Fail(@"could not synchronize both preference scopes");
    // Refresh the application-domain search list used for effective-value verification.
    return CFPreferencesAppSynchronize((__bridge CFStringRef)domain)
        ? YES : Fail(@"could not synchronize the effective application preference");
}

static void SetScope(NSString *domain, CFStringRef host, id value) {
    CFPreferencesSetValue((__bridge CFStringRef)PreferenceKey, (__bridge CFPropertyListRef)value,
        (__bridge CFStringRef)domain, kCFPreferencesCurrentUser, host);
}

static BOOL EqualValues(id left, id right) {
    return (!left && !right) || (left && right && CFEqual((__bridge CFTypeRef)left,
                                                        (__bridge CFTypeRef)right));
}

static BOOL Apply(NSString *domain, NSString *path) {
    int directory = OpenStateDirectory(path, YES);
    if (directory < 0) return NO;
    BOOL missing = NO;
    NSDictionary *state = ReadState(directory, path.lastPathComponent, domain, &missing);
    if (!state && !missing) { close(directory); return NO; }
    if (missing) {
        state = @{ @"version": @(StateVersion), @"uid": @(getuid()), @"app": domain,
                   @"key": PreferenceKey,
                   @"anyHost": StoredValue(CopyPreference(domain, kCFPreferencesAnyHost)),
                   @"currentHost": StoredValue(CopyPreference(domain, kCFPreferencesCurrentHost)) };
        if (!CreateState(directory, path.lastPathComponent, state)) { close(directory); return NO; }
    }
    close(directory);
    SetScope(domain, kCFPreferencesAnyHost, @NO);
    SetScope(domain, kCFPreferencesCurrentHost, @NO);
    if (!Synchronize(domain)) return NO;
    if (!IsFalse(CopyPreference(domain, kCFPreferencesAnyHost)) ||
        !IsFalse(CopyPreference(domain, kCFPreferencesCurrentHost)) || !IsFalse(CopyEffective(domain)))
        return Fail(@"software-backend preference did not become false in both scopes and effective lookup");
    NSMutableDictionary *result = [Status(domain) mutableCopy];
    result[@"action"] = @"apply";
    result[@"backup"] = path;
    result[@"backupCreated"] = @(missing);
    return PrintJSON(result);
}

static BOOL Restore(NSString *domain, NSString *path) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) {
        if (errno == ENOENT)
            return PrintJSON(@{ @"action": @"restore", @"restored": @NO,
                                @"reason": @"no_backup", @"domain": domain });
        return FailErrno(@"inspect backup path");
    }
    int directory = OpenStateDirectory(path, NO);
    if (directory < 0) return NO;
    BOOL missing = NO;
    NSDictionary *state = ReadState(directory, path.lastPathComponent, domain, &missing);
    if (!state) { close(directory); return missing ? Fail(@"backup disappeared during restore") : NO; }
    id any = [state[@"anyHost"][@"present"] boolValue] ? state[@"anyHost"][@"value"] : nil;
    id host = [state[@"currentHost"][@"present"] boolValue] ? state[@"currentHost"][@"value"] : nil;
    SetScope(domain, kCFPreferencesAnyHost, any);
    SetScope(domain, kCFPreferencesCurrentHost, host);
    if (!Synchronize(domain) || !EqualValues(CopyPreference(domain, kCFPreferencesAnyHost), any) ||
        !EqualValues(CopyPreference(domain, kCFPreferencesCurrentHost), host)) {
        close(directory);
        return Fail(@"restored preferences could not be verified; backup retained");
    }
    if (unlinkat(directory, path.lastPathComponent.fileSystemRepresentation, 0) != 0) {
        close(directory); return FailErrno(@"remove successfully restored backup");
    }
    BOOL ok = fsync(directory) == 0;
    if (!ok) FailErrno(@"sync restored backup directory");
    close(directory);
    if (!ok) return NO;
    NSMutableDictionary *result = [Status(domain) mutableCopy];
    result[@"action"] = @"restore";
    result[@"restored"] = @YES;
    return PrintJSON(result);
}

int main(void) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        NSUInteger index = 1;
        NSString *domain = DockDomain;
        if (arguments.count > index && [arguments[index] isEqual:@"--domain"]) {
            if (arguments.count <= index + 1) { Fail(@"missing test domain"); return 2; }
            domain = arguments[index + 1];
            if (![domain hasPrefix:@"org.launchpadrestore.test."] ||
                [domain rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
                Fail(@"--domain only accepts isolated org.launchpadrestore.test.* domains"); return 2;
            }
            index += 2;
        }
        if (arguments.count == index + 1 && [arguments[index] isEqual:@"--status"])
            return PrintJSON(Status(domain)) ? 0 : 1;
        if (arguments.count != index + 2 ||
            (![arguments[index] isEqual:@"--apply"] && ![arguments[index] isEqual:@"--restore"])) {
            Fail(@"usage: ca-render-backend [--domain org.launchpadrestore.test.NAME] --status | --apply STATE | --restore STATE");
            return 2;
        }
        if (getuid() == 0 || geteuid() == 0) {
            Fail(@"apply and restore must run as the desktop user, never as root"); return 2;
        }
        NSString *path = arguments[index + 1].stringByExpandingTildeInPath.stringByStandardizingPath;
        if (!path.isAbsolutePath || [path.lastPathComponent isEqual:@"/"]) {
            Fail(@"backup path must name an absolute file path"); return 2;
        }
        return ([arguments[index] isEqual:@"--apply"] ? Apply(domain, path) : Restore(domain, path)) ? 0 : 1;
    }
}

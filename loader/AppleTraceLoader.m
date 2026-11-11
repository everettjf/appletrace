//
//  AppleTraceLoader.m
//  Tweak that loads appletrace.framework into apps chosen on the command line
//  (`appletrace jb enable <bundle-id>`). Works on rootless (/var/jb) and
//  roothide (.jbroot-XXXX) jailbreaks without linking either's support
//  library: the jailbreak root is derived from this dylib's own path.
//
//  At launch of any UIKit process it looks for
//      <jbroot>/var/mobile/Library/AppleTrace/<bundle-id>.plist
//  — a dictionary of APPLETRACE_* environment variables. When present, the
//  variables are exported (so the framework's +load sees e.g.
//  APPLETRACE_AUTO_HOOK_OBJC_MSGSEND before it runs) and
//      <jbroot>/Library/Frameworks/appletrace.framework/appletrace
//  is dlopen'ed. Processes without a config file are left untouched.
//
//  For apps that have a config file, a short status log is written to the
//  app's own tmp/AppleTraceLoader.log (always writable from the sandbox) so
//  `appletrace jb pull` can show why an app was or wasn't traced.
//

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

static void AppleTraceLoaderLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void AppleTraceLoaderLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"AppleTraceLoader: %@", message);

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"AppleTraceLoader.log"];
    NSString *line = [NSString stringWithFormat:@"%@ [%d] %@\n", [NSDate date], getpid(), message];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

static NSString *AppleTraceJailbreakRoot(void) {
    Dl_info info;
    if (!dladdr((const void *)&AppleTraceJailbreakRoot, &info) || !info.dli_fname) {
        return nil;
    }
    char resolved[PATH_MAX];
    const char *path = realpath(info.dli_fname, resolved) ? resolved : info.dli_fname;

    // roothide: /var/containers/Bundle/Application/.jbroot-XXXXXXXX/...
    const char *roothide = strstr(path, "/.jbroot-");
    if (roothide) {
        const char *end = strchr(roothide + 1, '/');
        size_t length = end ? (size_t)(end - path) : strlen(path);
        return [[NSString alloc] initWithBytes:path length:length encoding:NSUTF8StringEncoding];
    }
    // rootless (Dopamine & co.): /private/preboot/<hash>/jb-XXXX/procursus/...
    const char *procursus = strstr(path, "/procursus/");
    if (procursus) {
        size_t length = (size_t)(procursus - path) + strlen("/procursus");
        return [[NSString alloc] initWithBytes:path length:length encoding:NSUTF8StringEncoding];
    }
    if (strncmp(path, "/var/jb/", 8) == 0) {
        return @"/var/jb";
    }
    return @"";  // rootful
}

__attribute__((constructor)) static void AppleTraceLoaderInit(void) {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID.length) {
            return;
        }
        NSString *jbroot = AppleTraceJailbreakRoot();
        if (!jbroot) {
            return;
        }

        NSString *configPath = [jbroot stringByAppendingPathComponent:
            [NSString stringWithFormat:@"var/mobile/Library/AppleTrace/%@.plist", bundleID]];
        NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:configPath];
        if (![config isKindOfClass:[NSDictionary class]]) {
            if (access(configPath.fileSystemRepresentation, F_OK) == 0) {
                AppleTraceLoaderLog(@"config %@ exists but could not be read (errno %d)", configPath, errno);
            }
            return;
        }
        AppleTraceLoaderLog(@"%@: jbroot %@, config %@", bundleID, jbroot, configPath);

        for (id key in config) {
            id value = config[key];
            if (![key isKindOfClass:[NSString class]] || ![(NSString *)key hasPrefix:@"APPLETRACE_"]) {
                continue;
            }
            NSString *text = [value isKindOfClass:[NSString class]] ? value
                           : [value respondsToSelector:@selector(stringValue)] ? [value stringValue]
                           : nil;
            if (text) {
                setenv([(NSString *)key UTF8String], text.UTF8String, 1);
            }
        }

        NSString *framework = [jbroot stringByAppendingPathComponent:
            @"Library/Frameworks/appletrace.framework/appletrace"];
        void *handle = dlopen(framework.fileSystemRepresentation, RTLD_NOW);
        if (!handle) {
            AppleTraceLoaderLog(@"failed to load %@: %s", framework, dlerror());
            return;
        }
        const char *(*hookDiagnostics)(void) = (const char *(*)(void))dlsym(handle, "APTObjcMsgSendHookDiagnostics");
        const char *(*traceDirectory)(void) = (const char *(*)(void))dlsym(handle, "APTGetTraceDirectory");
        AppleTraceLoaderLog(@"loaded %@; objc_msgSend hook: %s; traces in %s", framework,
                            hookDiagnostics ? hookDiagnostics() : "?",
                            traceDirectory ? traceDirectory() : "?");
    }
}

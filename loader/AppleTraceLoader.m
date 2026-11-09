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

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

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
            return;
        }

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
            NSLog(@"AppleTraceLoader: failed to load %@: %s", framework, dlerror());
            return;
        }
        NSLog(@"AppleTraceLoader: loaded AppleTrace into %@ (config %@)", bundleID, configPath);
    }
}

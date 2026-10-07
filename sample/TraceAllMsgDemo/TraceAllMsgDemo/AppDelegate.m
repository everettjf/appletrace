//
//  AppDelegate.m
//  TraceAllMsgDemo
//
//  Created by everettjf on 21/09/2017.
//  Copyright © 2017 everettjf. All rights reserved.
//

#import "AppDelegate.h"
#import <appletrace/appletrace.h>
#import <fcntl.h>
#import <dlfcn.h>
#import <limits.h>
#import <string.h>
#import <unistd.h>
#import "ViewController.h"
#import "ThreadTest.h"

@interface APTSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation APTSceneDelegate
@end

@interface APTSuperBase : NSObject
- (void)superPing;
@end

@implementation APTSuperBase

- (void)superPing {
    usleep(20);
}

@end

@interface APTSuperChild : APTSuperBase
- (void)invokeSuperPing;
@end

@implementation APTSuperChild

- (void)invokeSuperPing {
    [super superPing];
}

@end

@interface AppDelegate ()
@property (nonatomic, assign) BOOL didStartTraceScenario;

@end

@implementation AppDelegate

static BOOL APTBoolFromEnvironment(NSString *key) {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:key];
    if (!value.length) {
        return NO;
    }

    NSString *normalized = value.lowercaseString;
    return ![normalized isEqualToString:@"0"] &&
           ![normalized isEqualToString:@"false"] &&
           ![normalized isEqualToString:@"no"];
}

static BOOL APTProcessHasArgument(NSString *argument) {
    return [[[NSProcessInfo processInfo] arguments] containsObject:argument];
}

static BOOL APTExperimentalMarkerExists(void) {
    NSString *libraryPath = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    NSString *markerPath = [libraryPath stringByAppendingPathComponent:@"appletrace_experimental.flag"];
    return [[NSFileManager defaultManager] fileExistsAtPath:markerPath];
}

static void APTAppendScenarioProgress(const char *step) {
    if (!step) {
        return;
    }

    const char *home = getenv("HOME");
    if (!home || home[0] == '\0') {
        return;
    }

    char progressPath[PATH_MAX];
    int written = snprintf(progressPath,
                           sizeof(progressPath),
                           "%s/Library/appletracedata/scenario-progress.log",
                           home);
    if (written <= 0 || written >= (int)sizeof(progressPath)) {
        return;
    }

    int fd = open(progressPath, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd < 0) {
        return;
    }

    size_t stepLength = strlen(step);
    char *line = malloc(stepLength + 2);
    if (line) {
        memcpy(line, step, stepLength);
        line[stepLength] = '\n';
        line[stepLength + 1] = '\0';
        (void)write(fd, line, stepLength + 1);
        free(line);
    }
    (void)close(fd);
    (void)write(STDERR_FILENO, "AppleTrace progress: ", 21);
    (void)write(STDERR_FILENO, step, strlen(step));
    (void)write(STDERR_FILENO, "\n", 1);
}

static void APTAppendScenarioProgressDouble(const char *label, double value) {
    char buffer[128];
    int written = snprintf(buffer, sizeof(buffer), "%s=%.2f", label, value);
    if (written <= 0 || written >= (int)sizeof(buffer)) {
        return;
    }

    APTAppendScenarioProgress(buffer);
}

static void APTAppendScenarioProgressRange(const char *label, NSRange range) {
    char buffer[128];
    int written = snprintf(buffer, sizeof(buffer), "%s=%lu,%lu", label, (unsigned long)range.location, (unsigned long)range.length);
    if (written <= 0 || written >= (int)sizeof(buffer)) {
        return;
    }

    APTAppendScenarioProgress(buffer);
}

static void APTAppendScenarioProgressInsets(const char *label, UIEdgeInsets insets) {
    char buffer[128];
    int written = snprintf(buffer,
                           sizeof(buffer),
                           "%s=%.2f,%.2f,%.2f,%.2f",
                           label,
                           insets.top,
                           insets.left,
                           insets.bottom,
                           insets.right);
    if (written <= 0 || written >= (int)sizeof(buffer)) {
        return;
    }

    APTAppendScenarioProgress(buffer);
}


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for customization after application launch.
    NSLog(@"AppleTrace trace directory: %s", APTGetTraceDirectory());
    NSTimeInterval t = [UIApplication sharedApplication].backgroundTimeRemaining;
    NSLog(@"%@",@(t));
    [self scheduleTraceScenarioIfNeeded];

    return YES;
}
- (void)myTest{
//    NSLog(@"my test");
}

- (void)filterDeniedProbe {
    usleep(10);
}

- (void)filterAllowedProbe {
    usleep(10);
}

- (void)levelOne{
    usleep(50);
    [self levelTwo];
}

- (void)levelTwo{
    usleep(50);
    [self levelThree];
}

- (void)levelThree{
    usleep(50);
    
    [[self class]staticMethod:@"hi"];
}

- (void)manyArgs:(NSString *)arg1
              a2:(NSString *)arg2
              a3:(NSString *)arg3
              a4:(NSString *)arg4
              a5:(NSString *)arg5
              a6:(NSString *)arg6
              a7:(NSString *)arg7
              a8:(NSString *)arg8
              a9:(NSString *)arg9
             a10:(NSString *)arg10{
    if (arg1.length + arg10.length == 0) {
        NSLog(@"%@%@%@%@%@%@%@%@%@%@", arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10);
    }
}

- (double)sumDoubles:(double)a1
                  b:(double)a2
                  c:(double)a3
                  d:(double)a4
                  e:(double)a5
                  f:(double)a6
                  g:(double)a7
                  h:(double)a8
                  i:(double)a9
                  j:(double)a10{
    return a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10;
}

- (NSRange)makeRangeLocation:(NSUInteger)location length:(NSUInteger)length {
    return NSMakeRange(location, length);
}

- (UIEdgeInsets)makeInsetsTop:(CGFloat)top
                         left:(CGFloat)left
                       bottom:(CGFloat)bottom
                        right:(CGFloat)right {
    return UIEdgeInsetsMake(top, left, bottom, right);
}

+ (BOOL)staticMethod:(NSString*)words{
    usleep(100);
    return YES;
}





- (void)applicationWillResignActive:(UIApplication *)application {
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
}


- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    APTFlush();
}


- (void)applicationWillEnterForeground:(UIApplication *)application {
    // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
}


- (void)applicationDidBecomeActive:(UIApplication *)application {
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    [self scheduleTraceScenarioIfNeeded];
}


- (void)applicationWillTerminate:(UIApplication *)application {
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    APTFlush();
}

- (void)runTraceScenario {
    APTAppendScenarioProgress("runTraceScenario:entry");
    NSLog(@"AppleTrace experimental scenario started");
    APTAppendScenarioProgress("runTraceScenario:after-log");
    APTBeginSection("appletrace-experimental-scenario");
    APTAppendScenarioProgress("runTraceScenario:after-experimental-begin");
    APTBeginSection("appletrace-smoke-scenario");
    APTAppendScenarioProgress("runTraceScenario:after-smoke-begin");
    [self myTest];
    APTAppendScenarioProgress("runTraceScenario:after-myTest");
    usleep(200);
    APTAppendScenarioProgress("runTraceScenario:after-usleep");

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        APTAppendScenarioProgress("runTraceScenario:block1-entry");
        ThreadTest *t = [[ThreadTest alloc] init];
        APTAppendScenarioProgress("runTraceScenario:block1-after-alloc");
        [t go];
        APTAppendScenarioProgress("runTraceScenario:block1-after-go");
        APTFlush();
        APTAppendScenarioProgress("runTraceScenario:block1-after-flush");
    });

    APTAppendScenarioProgress("runTraceScenario:before-levelOne");
    [self levelOne];
    APTAppendScenarioProgress("runTraceScenario:after-levelOne");
    [self manyArgs:@"1"
                a2:@"2"
                a3:@"3"
                a4:@"4"
                a5:@"5"
                a6:@"6"
                a7:@"7"
                a8:@"8"
                a9:@"9"
               a10:@"10"];
    APTAppendScenarioProgress("runTraceScenario:after-manyArgs");
    double sum = [self sumDoubles:1.0
                                b:2.0
                                c:3.0
                                d:4.0
                                e:5.0
                                f:6.0
                                g:7.0
                                h:8.0
                                i:9.0
                                j:10.0];
    APTAppendScenarioProgressDouble("runTraceScenario:doubleSum", sum);
    APTAppendScenarioProgress("runTraceScenario:after-doubleSum");
    NSRange range = [self makeRangeLocation:12 length:34];
    APTAppendScenarioProgressRange("runTraceScenario:range", range);
    APTAppendScenarioProgress("runTraceScenario:after-range");
    UIEdgeInsets insets = [self makeInsetsTop:1.0 left:2.0 bottom:3.0 right:4.0];
    APTAppendScenarioProgressInsets("runTraceScenario:insets", insets);
    APTAppendScenarioProgress("runTraceScenario:after-insets");
    APTSuperChild *superChild = [[APTSuperChild alloc] init];
    [superChild invokeSuperPing];
    APTAppendScenarioProgress("runTraceScenario:after-superPing");

    // Verify that runtime filter updates invalidate cached (Class, SEL)
    // decisions without invalidating names borrowed by active call stacks.
    APTSetObjcTraceClassFilters("NoMatchingClass", NULL);
    [self filterDeniedProbe];
    APTSetObjcTraceClassFilters("AppDelegate", NULL);
    [self filterAllowedProbe];
    APTSetObjcTraceClassFilters(NULL, NULL);
    APTAppendScenarioProgress("runTraceScenario:after-runtime-filter");

    NSString *lateProbePath = [[NSBundle mainBundle] pathForResource:@"TraceLateLoad" ofType:@"dylib"];
    if (lateProbePath.length) {
        void *lateProbeHandle = dlopen(lateProbePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        void (*invokeLateProbe)(void) = lateProbeHandle ? dlsym(lateProbeHandle, "APTInvokeLateLoadedProbe") : NULL;
        if (invokeLateProbe) {
            invokeLateProbe();
            APTAppendScenarioProgress("runTraceScenario:after-late-loaded-probe");
        } else {
            APTAppendScenarioProgress("runTraceScenario:late-loaded-probe-failed");
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        APTAppendScenarioProgress("runTraceScenario:block2-entry");
        APTEndSection("appletrace-smoke-scenario");
        APTAppendScenarioProgress("runTraceScenario:block2-after-smoke-end");
        APTEndSection("appletrace-experimental-scenario");
        APTAppendScenarioProgress("runTraceScenario:block2-after-experimental-end");
        APTSyncWait();
        APTAppendScenarioProgress("runTraceScenario:block2-after-sync");
        APTFlush();
        APTAppendScenarioProgress("runTraceScenario:block2-after-flush");
    });
}

- (void)scheduleTraceScenarioIfNeeded {
    if (self.didStartTraceScenario) {
        return;
    }

    self.didStartTraceScenario = YES;
    // Start promptly so simulator automation cannot background the sample
    // before the scenario begins. The scenario itself still exercises delayed
    // main-queue completion and background concurrency.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        BOOL shouldRunExperimental = APTBoolFromEnvironment(@"APPLETRACE_EXPERIMENTAL_SCENARIO") ||
                                     APTProcessHasArgument(@"-AppleTraceExperimentalScenario") ||
                                     APTExperimentalMarkerExists();
        NSLog(@"AppleTrace experimental requested: %@", shouldRunExperimental ? @"YES" : @"NO");
        BOOL installed = APTInstallObjcMsgSendHook();
        if (installed) {
            APTBeginSection("appletrace-smoke-scenario");
            APTEndSection("appletrace-smoke-scenario");
            APTSyncWait();

            if (shouldRunExperimental) {
                [self runTraceScenario];
            }
        }
    });
}


@end

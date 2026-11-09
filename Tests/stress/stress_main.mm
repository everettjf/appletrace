//
//  stress_main.mm
//  AppleTrace batched-writer stress harness.
//
//  Spawns worker threads that each emit a fixed number of nested
//  outer/inner begin/end pairs, plus "dyn_N" sections whose names are written
//  into one reused stack buffer (exercising the binary writer's pointer cache
//  with changing contents). Worker threads exit before the flush so the
//  pthread-key drain path runs alongside the background drain and APTFlush.
//  scripts/test_batching_stress.sh asserts the exact counts and nesting.
//
//  Modes (argv[1]):
//    (none)     flush explicitly, then exit
//    no-flush   exit without APTFlush (the exit handler must drain)
//    hang       print READY and sleep (the script SIGKILLs it; the background
//               drain must already have written everything)
//

#import <Foundation/Foundation.h>

#include <cstdio>
#include <cstring>
#include <thread>
#include <unistd.h>
#include <vector>

#import "appletrace.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const char *mode = argc > 1 ? argv[1] : "";
        const int thread_count = 8;
        const int pairs_per_thread = 25000;
        const int dynamic_names = 7;

        std::vector<std::thread> workers;
        workers.reserve(thread_count);
        for (int t = 0; t < thread_count; ++t) {
            workers.emplace_back([pairs_per_thread, dynamic_names]() {
                char name[32];
                for (int i = 0; i < pairs_per_thread; ++i) {
                    APTBeginSection("outer");
                    APTBeginSection("inner");
                    APTEndSection("inner");
                    APTEndSection("outer");

                    snprintf(name, sizeof(name), "dyn_%d", i % dynamic_names);
                    APTBeginSection(name);
                    APTEndSection(name);
                }
            });
        }
        for (std::thread &worker : workers) {
            worker.join();  // thread exit triggers the per-thread drain path
        }

        // Smoke the other event types (not counted by the assertion).
        APTInstant("stress_done");
        APTCounter("stress_threads", thread_count);
        uint64_t async_id = APTNewAsyncID();
        APTAsyncBegin("stress_async", async_id);
        APTAsyncEnd("stress_async", async_id);

        const long expected = (long)thread_count * pairs_per_thread;
        fprintf(stdout, "EXPECTED_STRESS_PAIRS=%ld\n", expected);
        fprintf(stdout, "TRACE_DIR=%s\n", APTGetTraceDirectory());
        fflush(stdout);

        if (strcmp(mode, "hang") == 0) {
            fprintf(stdout, "READY\n");
            fflush(stdout);
            for (;;) {
                sleep(60);
            }
        }
        if (strcmp(mode, "no-flush") != 0) {
            APTFlush();
            APTSyncWait();
        }
    }
    return 0;
}

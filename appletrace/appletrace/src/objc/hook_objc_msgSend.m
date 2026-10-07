/**
 * AppleTrace objc_msgSend tracing runtime.
 *
 * Targets arm64 and arm64e. It uses fishhook-style symbol rebinding plus an assembly
 * wrapper so objc_msgSend arguments and return registers survive the tracing
 * callbacks.
 *
 * On arm64e, authenticated GOT entries use the standard function-pointer
 * schema: IA key, storage-address diversity, and discriminator zero. Replacement
 * pointers are stripped and re-signed for each slot before they are installed.
 * The implementation is intentionally local and MIT-licensed; it does not copy
 * code from Frida Gum or another hooking library.
 */

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>

#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

#ifndef LC_DYLD_CHAINED_FIXUPS
#define LC_DYLD_CHAINED_FIXUPS 0x80000034
#endif

#import "appletrace.h"

#if !defined(__arm64__)
#error AppleTrace objc_msgSend hook requires arm64.
#endif

typedef void (*APTObjcMsgSendFunction)(void);
typedef void (*APTObjcMsgSendSuper2Function)(void);

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

struct APTRebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

struct APTRebindingsEntry {
    struct APTRebinding *rebindings;
    size_t count;
    struct APTRebindingsEntry *next;
};

// Per-thread call stack of interned section names. The names are borrowed
// (interned for the process lifetime), so the stack only stores pointers and
// never allocates on the hot path after the initial growth.
typedef struct APTThreadStack {
    const char **items;
    size_t count;
    size_t capacity;
} APTThreadStack;

// Interned (Class, SEL) -> formatted name. A NULL name caches a "do not trace"
// decision so the hot path never rebuilds a string or re-evaluates filters.
typedef struct APTNameEntry {
    Class cls;
    SEL sel;
    const char *name;
    uint64_t filter_generation;
    struct APTNameEntry *next;
} APTNameEntry;

#define APT_INTERN_BUCKET_COUNT 8192

static uintptr_t gLogSelectorStart = 0;
static uintptr_t gLogSelectorEnd = 0;
static uintptr_t gLogClassStart = 0;
static uintptr_t gLogClassEnd = 0;
static int gLogAllSelectors = 1;
static int gLogAllClasses = 1;
static char **gAllowPrefixes = NULL;
static size_t gAllowPrefixCount = 0;
static char **gDenyPrefixes = NULL;
static size_t gDenyPrefixCount = 0;
static uint64_t gFilterGeneration = 1;
static __thread int gTraceGuard = 0;
static pthread_key_t gTraceStackKey;
static pthread_once_t gTraceStackKeyOnce = PTHREAD_ONCE_INIT;
static APTNameEntry *gInternBuckets[APT_INTERN_BUCKET_COUNT];
static os_unfair_lock gInternLock = OS_UNFAIR_LOCK_INIT;
static dispatch_once_t gHookInstallOnce;
static APTObjcMsgSendFunction apt_original_objc_msgSend = NULL;
static APTObjcMsgSendSuper2Function apt_original_objc_msgSendSuper2 = NULL;
static struct APTRebindingsEntry *gRebindingsHead = NULL;
static BOOL gHookInstalled = NO;
static BOOL gDyldCallbackRegistered = NO;

__attribute__((used)) static void apt_before_objc_msgSend(id object, SEL selector);
__attribute__((used)) static void apt_before_objc_msgSendSuper2(struct objc_super *super_info, SEL selector);
__attribute__((used)) static void apt_after_objc_msgSend(void);
static void apt_configure_trace_ranges(void);
static int apt_rebind_symbols(struct APTRebinding rebindings[], size_t count);
static void apt_rebind_symbols_for_image(const struct mach_header *header,
                                         intptr_t slide,
                                         struct APTRebindingsEntry *rebindings);
extern void apt_objc_msgSend_wrapper(void);
extern void apt_objc_msgSendSuper2_wrapper(void);

#if __has_feature(ptrauth_calls)
#define APT_ASM_ENTRY "bti c\n" "paciasp\n"
#define APT_ASM_CALL_ORIGINAL "blraaz x16\n"
#define APT_ASM_RETURN "autiasp\n"
#else
#define APT_ASM_ENTRY
#define APT_ASM_CALL_ORIGINAL "blr x16\n"
#define APT_ASM_RETURN
#endif

static BOOL apt_bool_from_environment(NSString *key, BOOL fallback) {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:key];
    if (!value.length) {
        return fallback;
    }

    NSString *normalized = value.lowercaseString;
    return ![normalized isEqualToString:@"0"] &&
           ![normalized isEqualToString:@"false"] &&
           ![normalized isEqualToString:@"no"];
}

static BOOL apt_install_objc_msgsend_hook(void) {
    __block BOOL installed = NO;
    dispatch_once(&gHookInstallOnce, ^{
        apt_configure_trace_ranges();
        apt_original_objc_msgSend = (APTObjcMsgSendFunction)dlsym(RTLD_DEFAULT, "objc_msgSend");
        apt_original_objc_msgSendSuper2 = (APTObjcMsgSendSuper2Function)dlsym(RTLD_DEFAULT, "objc_msgSendSuper2");
        if (apt_original_objc_msgSend == NULL || apt_original_objc_msgSendSuper2 == NULL) {
            NSLog(@"AppleTrace: failed to resolve objc_msgSend symbols before rebinding");
            return;
        }

        struct APTRebinding rebindings[] = {
            {
                .name = "objc_msgSend",
                .replacement = (void *)apt_objc_msgSend_wrapper,
                .replaced = (void **)&apt_original_objc_msgSend,
            },
            {
                .name = "objc_msgSendSuper2",
                .replacement = (void *)apt_objc_msgSendSuper2_wrapper,
                .replaced = (void **)&apt_original_objc_msgSendSuper2,
            },
        };

        int status = apt_rebind_symbols(rebindings, 2);
        if (status == 0 && apt_original_objc_msgSend != NULL && apt_original_objc_msgSendSuper2 != NULL) {
            gHookInstalled = YES;
        }
    });

    installed = gHookInstalled;
    return installed;
}

__asm__(
".text\n"
".align 2\n"
".globl _apt_objc_msgSend_wrapper\n"
"_apt_objc_msgSend_wrapper:\n"
APT_ASM_ENTRY
"sub sp, sp, #0x1C0\n"
"stp x29, x30, [sp, #0x1B0]\n"
"mov x29, sp\n"
"add x11, sp, #0x1C0\n"
"ldp x9, x10, [x11, #0x00]\n"
"stp x9, x10, [sp, #0x00]\n"
"ldp x9, x10, [x11, #0x10]\n"
"stp x9, x10, [sp, #0x10]\n"
"ldp x9, x10, [x11, #0x20]\n"
"stp x9, x10, [sp, #0x20]\n"
"ldp x9, x10, [x11, #0x30]\n"
"stp x9, x10, [sp, #0x30]\n"
"ldp x9, x10, [x11, #0x40]\n"
"stp x9, x10, [sp, #0x40]\n"
"ldp x9, x10, [x11, #0x50]\n"
"stp x9, x10, [sp, #0x50]\n"
"ldp x9, x10, [x11, #0x60]\n"
"stp x9, x10, [sp, #0x60]\n"
"ldp x9, x10, [x11, #0x70]\n"
"stp x9, x10, [sp, #0x70]\n"
"stp x0, x1, [sp, #0x80]\n"
"stp x2, x3, [sp, #0x90]\n"
"stp x4, x5, [sp, #0xA0]\n"
"stp x6, x7, [sp, #0xB0]\n"
"str x8, [sp, #0xC0]\n"
"stp q0, q1, [sp, #0xD0]\n"
"stp q2, q3, [sp, #0xF0]\n"
"stp q4, q5, [sp, #0x110]\n"
"stp q6, q7, [sp, #0x130]\n"
"bl _apt_before_objc_msgSend\n"
"ldp x0, x1, [sp, #0x80]\n"
"ldp x2, x3, [sp, #0x90]\n"
"ldp x4, x5, [sp, #0xA0]\n"
"ldp x6, x7, [sp, #0xB0]\n"
"ldr x8, [sp, #0xC0]\n"
"ldp q0, q1, [sp, #0xD0]\n"
"ldp q2, q3, [sp, #0xF0]\n"
"ldp q4, q5, [sp, #0x110]\n"
"ldp q6, q7, [sp, #0x130]\n"
"adrp x16, _apt_original_objc_msgSend@PAGE\n"
"ldr x16, [x16, _apt_original_objc_msgSend@PAGEOFF]\n"
APT_ASM_CALL_ORIGINAL
"stp x0, x1, [sp, #0x80]\n"
"stp q0, q1, [sp, #0xD0]\n"
"stp q2, q3, [sp, #0xF0]\n"
"bl _apt_after_objc_msgSend\n"
"ldp x0, x1, [sp, #0x80]\n"
"ldp q0, q1, [sp, #0xD0]\n"
"ldp q2, q3, [sp, #0xF0]\n"
"ldp x29, x30, [sp, #0x1B0]\n"
"add sp, sp, #0x1C0\n"
APT_ASM_RETURN
"ret\n"
".globl _apt_objc_msgSendSuper2_wrapper\n"
"_apt_objc_msgSendSuper2_wrapper:\n"
APT_ASM_ENTRY
"sub sp, sp, #0x1C0\n"
"stp x29, x30, [sp, #0x1B0]\n"
"mov x29, sp\n"
"add x11, sp, #0x1C0\n"
"ldp x9, x10, [x11, #0x00]\n"
"stp x9, x10, [sp, #0x00]\n"
"ldp x9, x10, [x11, #0x10]\n"
"stp x9, x10, [sp, #0x10]\n"
"ldp x9, x10, [x11, #0x20]\n"
"stp x9, x10, [sp, #0x20]\n"
"ldp x9, x10, [x11, #0x30]\n"
"stp x9, x10, [sp, #0x30]\n"
"ldp x9, x10, [x11, #0x40]\n"
"stp x9, x10, [sp, #0x40]\n"
"ldp x9, x10, [x11, #0x50]\n"
"stp x9, x10, [sp, #0x50]\n"
"ldp x9, x10, [x11, #0x60]\n"
"stp x9, x10, [sp, #0x60]\n"
"ldp x9, x10, [x11, #0x70]\n"
"stp x9, x10, [sp, #0x70]\n"
"stp x0, x1, [sp, #0x80]\n"
"stp x2, x3, [sp, #0x90]\n"
"stp x4, x5, [sp, #0xA0]\n"
"stp x6, x7, [sp, #0xB0]\n"
"str x8, [sp, #0xC0]\n"
"stp q0, q1, [sp, #0xD0]\n"
"stp q2, q3, [sp, #0xF0]\n"
"stp q4, q5, [sp, #0x110]\n"
"stp q6, q7, [sp, #0x130]\n"
"bl _apt_before_objc_msgSendSuper2\n"
"ldp x0, x1, [sp, #0x80]\n"
"ldp x2, x3, [sp, #0x90]\n"
"ldp x4, x5, [sp, #0xA0]\n"
"ldp x6, x7, [sp, #0xB0]\n"
"ldr x8, [sp, #0xC0]\n"
"ldp q0, q1, [sp, #0xD0]\n"
"ldp q2, q3, [sp, #0xF0]\n"
"ldp q4, q5, [sp, #0x110]\n"
"ldp q6, q7, [sp, #0x130]\n"
"adrp x16, _apt_original_objc_msgSendSuper2@PAGE\n"
"ldr x16, [x16, _apt_original_objc_msgSendSuper2@PAGEOFF]\n"
APT_ASM_CALL_ORIGINAL
"stp x0, x1, [sp, #0x80]\n"
"stp q0, q1, [sp, #0xD0]\n"
"stp q2, q3, [sp, #0xF0]\n"
"bl _apt_after_objc_msgSend\n"
"ldp x0, x1, [sp, #0x80]\n"
"ldp q0, q1, [sp, #0xD0]\n"
"ldp q2, q3, [sp, #0xF0]\n"
"ldp x29, x30, [sp, #0x1B0]\n"
"add sp, sp, #0x1C0\n"
APT_ASM_RETURN
"ret\n"
);

static void apt_free_trace_stack(void *pointer) {
    APTThreadStack *stack = (APTThreadStack *)pointer;
    if (!stack) {
        return;
    }
    free(stack->items);
    free(stack);
}

static void apt_make_trace_stack_key(void) {
    pthread_key_create(&gTraceStackKey, apt_free_trace_stack);
}

static APTThreadStack *apt_trace_stack(void) {
    pthread_once(&gTraceStackKeyOnce, apt_make_trace_stack_key);
    APTThreadStack *stack = (APTThreadStack *)pthread_getspecific(gTraceStackKey);
    if (!stack) {
        stack = calloc(1, sizeof(APTThreadStack));
        if (stack) {
            pthread_setspecific(gTraceStackKey, stack);
        }
    }
    return stack;
}

// Pushes a borrowed (interned) name. NULL is a valid value: it keeps the stack
// balanced for sends that are filtered out so the matching pop does not unwind
// an unrelated parent section.
static void apt_trace_stack_push(const char *name) {
    APTThreadStack *stack = apt_trace_stack();
    if (!stack) {
        return;
    }

    if (stack->count == stack->capacity) {
        size_t new_capacity = stack->capacity ? stack->capacity * 2 : 64;
        const char **items = realloc(stack->items, new_capacity * sizeof(const char *));
        if (!items) {
            return;
        }
        stack->items = items;
        stack->capacity = new_capacity;
    }

    stack->items[stack->count++] = name;
}

static const char *apt_trace_stack_pop(BOOL *had_entry) {
    APTThreadStack *stack = apt_trace_stack();
    if (!stack || stack->count == 0) {
        if (had_entry) {
            *had_entry = NO;
        }
        return NULL;
    }
    if (had_entry) {
        *had_entry = YES;
    }
    return stack->items[--stack->count];
}

static struct section_64 *apt_find_section(struct mach_header_64 *header, const char *section_name) {
    struct load_command *command = (struct load_command *)((uintptr_t)header + sizeof(struct mach_header_64));
    for (uint32_t command_index = 0; command_index < header->ncmds; ++command_index) {
        if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *)command;
            struct section_64 *section = (struct section_64 *)((uintptr_t)segment + sizeof(struct segment_command_64));
            for (uint32_t section_index = 0; section_index < segment->nsects; ++section_index) {
                if (strncmp(section[section_index].sectname, section_name, sizeof(section[section_index].sectname)) == 0) {
                    return &section[section_index];
                }
            }
        }
        command = (struct load_command *)((uintptr_t)command + command->cmdsize);
    }
    return NULL;
}

static void apt_parse_prefix_list(NSString *key, char ***out_prefixes, size_t *out_count) {
    *out_prefixes = NULL;
    *out_count = 0;

    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:key];
    if (!value.length) {
        return;
    }

    NSMutableArray<NSString *> *parsed = [NSMutableArray array];
    for (NSString *component in [value componentsSeparatedByString:@","]) {
        NSString *trimmed = [component stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length) {
            [parsed addObject:trimmed];
        }
    }
    if (parsed.count == 0) {
        return;
    }

    char **prefixes = calloc(parsed.count, sizeof(char *));
    if (!prefixes) {
        return;
    }

    size_t count = 0;
    for (NSString *prefix in parsed) {
        prefixes[count] = strdup(prefix.UTF8String);
        if (prefixes[count]) {
            count += 1;
        }
    }

    *out_prefixes = prefixes;
    *out_count = count;
}

static void apt_free_prefix_list(char **prefixes, size_t count) {
    if (!prefixes) {
        return;
    }
    for (size_t index = 0; index < count; index++) {
        free(prefixes[index]);
    }
    free(prefixes);
}

static void apt_parse_prefix_string(const char *value, char ***out_prefixes, size_t *out_count) {
    *out_prefixes = NULL;
    *out_count = 0;
    if (!value || value[0] == '\0') {
        return;
    }

    NSString *input = [NSString stringWithUTF8String:value];
    if (!input.length) {
        return;
    }

    NSMutableArray<NSString *> *parsed = [NSMutableArray array];
    for (NSString *component in [input componentsSeparatedByString:@","]) {
        NSString *trimmed = [component stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length) {
            [parsed addObject:trimmed];
        }
    }
    if (parsed.count == 0) {
        return;
    }

    char **prefixes = calloc(parsed.count, sizeof(char *));
    if (!prefixes) {
        return;
    }

    size_t count = 0;
    for (NSString *prefix in parsed) {
        char *copy = strdup(prefix.UTF8String);
        if (copy) {
            prefixes[count++] = copy;
        }
    }
    *out_prefixes = prefixes;
    *out_count = count;
}

static void apt_configure_trace_ranges(void) {
    gLogAllSelectors = apt_bool_from_environment(@"APPLETRACE_TRACE_ALL_SELECTORS", YES);
    gLogAllClasses = apt_bool_from_environment(@"APPLETRACE_TRACE_ALL_CLASSES", YES);
    apt_parse_prefix_list(@"APPLETRACE_TRACE_CLASS_ALLOW", &gAllowPrefixes, &gAllowPrefixCount);
    apt_parse_prefix_list(@"APPLETRACE_TRACE_CLASS_DENY", &gDenyPrefixes, &gDenyPrefixCount);

    const struct mach_header *header = _dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC_64) {
        return;
    }

    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    struct section_64 *selector_section = apt_find_section((struct mach_header_64 *)header, "__objc_methname");
    if (selector_section) {
        gLogSelectorStart = (uintptr_t)(slide + selector_section->addr);
        gLogSelectorEnd = gLogSelectorStart + selector_section->size;
    }

    struct section_64 *class_section = apt_find_section((struct mach_header_64 *)header, "__objc_data");
    if (class_section) {
        gLogClassStart = (uintptr_t)(slide + class_section->addr);
        gLogClassEnd = gLogClassStart + class_section->size;
    }
}

static BOOL apt_selector_should_trace(const char *selector_name) {
    if (!selector_name) {
        return NO;
    }
    if (gLogAllSelectors) {
        return YES;
    }
    if (gLogSelectorStart == 0 || gLogSelectorEnd == 0) {
        return YES;
    }

    uintptr_t pointer = (uintptr_t)selector_name;
    return pointer >= gLogSelectorStart && pointer <= gLogSelectorEnd;
}

static BOOL apt_class_should_trace(Class cls) {
    if (!cls) {
        return NO;
    }
    if (gLogAllClasses) {
        return YES;
    }
    if (gLogClassStart == 0 || gLogClassEnd == 0) {
        return YES;
    }

    uintptr_t pointer = (uintptr_t)cls;
    return pointer >= gLogClassStart && pointer <= gLogClassEnd;
}

static BOOL apt_class_passes_filters(const char *class_name) {
    if (!class_name) {
        return NO;
    }

    for (size_t index = 0; index < gDenyPrefixCount; index++) {
        const char *prefix = gDenyPrefixes[index];
        if (strncmp(class_name, prefix, strlen(prefix)) == 0) {
            return NO;
        }
    }

    if (gAllowPrefixCount == 0) {
        return YES;
    }

    for (size_t index = 0; index < gAllowPrefixCount; index++) {
        const char *prefix = gAllowPrefixes[index];
        if (strncmp(class_name, prefix, strlen(prefix)) == 0) {
            return YES;
        }
    }
    return NO;
}

// Builds a freshly allocated "[Class]selector" name, or NULL when the pair
// should not be traced. Only called once per (Class, SEL) pair via interning.
static const char *apt_build_trace_name(Class cls, SEL selector) {
    if (!cls || !selector) {
        return NULL;
    }

    const char *selector_name = sel_getName(selector);
    if (!apt_selector_should_trace(selector_name)) {
        return NULL;
    }
    if (!apt_class_should_trace(cls)) {
        return NULL;
    }

    const char *class_name = class_getName(cls);
    if (!class_name || !selector_name) {
        return NULL;
    }
    if (!apt_class_passes_filters(class_name)) {
        return NULL;
    }

    size_t required = strlen(class_name) + strlen(selector_name) + 4;
    char *trace_name = malloc(required);
    if (!trace_name) {
        return NULL;
    }

    snprintf(trace_name, required, "[%s]%s", class_name, selector_name);
    return trace_name;
}

// Returns the interned name for a (Class, SEL) pair, building it on first sight.
// A NULL result is cached too, so filtered-out pairs cost a single lookup.
static const char *apt_intern_trace_name(Class cls, SEL selector) {
    if (!cls || !selector) {
        return NULL;
    }

    uintptr_t hash = (((uintptr_t)cls >> 3) * 2654435761u) ^
                     ((uintptr_t)sel_getName(selector) >> 3);
    size_t bucket = hash & (APT_INTERN_BUCKET_COUNT - 1);

    os_unfair_lock_lock(&gInternLock);
    for (APTNameEntry *entry = gInternBuckets[bucket]; entry; entry = entry->next) {
        if (entry->cls == cls && entry->sel == selector &&
            entry->filter_generation == gFilterGeneration) {
            const char *name = entry->name;
            os_unfair_lock_unlock(&gInternLock);
            return name;
        }
    }

    const char *name = apt_build_trace_name(cls, selector);
    APTNameEntry *entry = malloc(sizeof(APTNameEntry));
    if (entry) {
        entry->cls = cls;
        entry->sel = selector;
        entry->name = name;
        entry->filter_generation = gFilterGeneration;
        entry->next = gInternBuckets[bucket];
        gInternBuckets[bucket] = entry;
    }
    os_unfair_lock_unlock(&gInternLock);
    return name;
}

static void apt_before_objc_msgSend(id object, SEL selector) {
    if (gTraceGuard != 0) {
        return;
    }

    gTraceGuard += 1;
    const char *trace_name = NULL;
    if (object && selector) {
        trace_name = apt_intern_trace_name(object_getClass(object), selector);
    }
    apt_trace_stack_push(trace_name);
    if (trace_name) {
        APTBeginSection(trace_name);
    }
    gTraceGuard -= 1;
}

static void apt_before_objc_msgSendSuper2(struct objc_super *super_info, SEL selector) {
    if (gTraceGuard != 0) {
        return;
    }

    gTraceGuard += 1;
    const char *trace_name = NULL;
    if (super_info && super_info->receiver && selector) {
        Class current_class = super_info->super_class;
        Class target_class = current_class ? class_getSuperclass(current_class) : Nil;
        if (!target_class) {
            target_class = object_getClass(super_info->receiver);
        }
        trace_name = apt_intern_trace_name(target_class, selector);
    }
    apt_trace_stack_push(trace_name);
    if (trace_name) {
        APTBeginSection(trace_name);
    }
    gTraceGuard -= 1;
}

static void apt_after_objc_msgSend(void) {
    if (gTraceGuard != 0) {
        return;
    }

    gTraceGuard += 1;
    BOOL had_entry = NO;
    const char *trace_name = apt_trace_stack_pop(&had_entry);
    if (had_entry && trace_name) {
        APTEndSection(trace_name);
    }
    gTraceGuard -= 1;
}

static int apt_prepend_rebindings(struct APTRebindingsEntry **head,
                                  struct APTRebinding rebindings[],
                                  size_t count) {
    struct APTRebindingsEntry *entry = malloc(sizeof(struct APTRebindingsEntry));
    if (!entry) {
        return -1;
    }

    entry->rebindings = malloc(sizeof(struct APTRebinding) * count);
    if (!entry->rebindings) {
        free(entry);
        return -1;
    }

    memcpy(entry->rebindings, rebindings, sizeof(struct APTRebinding) * count);
    entry->count = count;
    entry->next = *head;
    *head = entry;
    return 0;
}

static void apt_perform_rebinding_with_section(struct APTRebindingsEntry *rebindings,
                                               section_t *section,
                                               intptr_t slide,
                                               nlist_t *symtab,
                                               char *strtab,
                                               uint32_t *indirect_symtab,
                                               BOOL image_uses_chained_fixups) {
    uint32_t *indirect_symbol_indices = indirect_symtab + section->reserved1;
    void **indirect_symbol_bindings = (void **)((uintptr_t)slide + section->addr);
    size_t entry_count = section->size / sizeof(void *);

#if __has_feature(ptrauth_calls)
    BOOL is_authenticated_got =
        strncmp(section->sectname, "__auth_got", sizeof(section->sectname)) == 0;
    if (is_authenticated_got && !image_uses_chained_fixups) {
        return;
    }
#endif

    kern_return_t protection_status = vm_protect(mach_task_self(),
                                                 (vm_address_t)indirect_symbol_bindings,
                                                 (vm_size_t)section->size,
                                                 0,
                                                 VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (protection_status != KERN_SUCCESS) {
        return;
    }

    for (size_t index = 0; index < entry_count; index++) {
        uint32_t symtab_index = indirect_symbol_indices[index];
        if (symtab_index == INDIRECT_SYMBOL_ABS ||
            symtab_index == INDIRECT_SYMBOL_LOCAL ||
            symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }

        char *symbol_name = strtab + symtab[symtab_index].n_un.n_strx;
        if (!symbol_name || symbol_name[0] != '_') {
            continue;
        }

        struct APTRebindingsEntry *entry = rebindings;
        while (entry) {
            for (size_t rebinding_index = 0; rebinding_index < entry->count; rebinding_index++) {
                struct APTRebinding *rebinding = &entry->rebindings[rebinding_index];
                if (strcmp(&symbol_name[1], rebinding->name) == 0) {
                    if (rebinding->replaced && *(rebinding->replaced) == NULL) {
                        *(rebinding->replaced) = indirect_symbol_bindings[index];
                    }
                    void *replacement = rebinding->replacement;
#if __has_feature(ptrauth_calls)
                    if (is_authenticated_got) {
                        void *slot = &indirect_symbol_bindings[index];
                        void *raw_replacement = ptrauth_strip(replacement, ptrauth_key_function_pointer);
                        uintptr_t discriminator = ptrauth_blend_discriminator(slot, 0);
                        replacement = ptrauth_sign_unauthenticated(raw_replacement,
                                                                  ptrauth_key_function_pointer,
                                                                  discriminator);
                    }
#endif
                    indirect_symbol_bindings[index] = replacement;
                    goto next_symbol;
                }
            }
            entry = entry->next;
        }

    next_symbol:
        continue;
    }

    // Keep the rebinding page writable after patching. Restoring it to a guessed
    // read-only protection can corrupt unrelated mutable globals that share the
    // same __DATA page, which caused simulator startup crashes.
}

static void apt_rebind_symbols_for_image(const struct mach_header *header,
                                         intptr_t slide,
                                         struct APTRebindingsEntry *rebindings) {
    Dl_info info;
    if (!header || !rebindings || !dladdr(header, &info)) {
        return;
    }
    if (info.dli_fname && strstr(info.dli_fname, "/appletrace.framework/") != NULL) {
        return;
    }

    segment_command_t *linkedit_segment = NULL;
    struct symtab_command *symtab_command = NULL;
    struct dysymtab_command *dysymtab_command = NULL;
    BOOL image_uses_chained_fixups = NO;

    uintptr_t command_cursor = (uintptr_t)header + sizeof(mach_header_t);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        struct load_command *command = (struct load_command *)command_cursor;
        if (command->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            segment_command_t *segment = (segment_command_t *)command;
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) {
                linkedit_segment = segment;
            }
        } else if (command->cmd == LC_SYMTAB) {
            symtab_command = (struct symtab_command *)command;
        } else if (command->cmd == LC_DYSYMTAB) {
            dysymtab_command = (struct dysymtab_command *)command;
        } else if (command->cmd == LC_DYLD_CHAINED_FIXUPS) {
            // The authenticated pointer layout is described by dyld chained
            // fixups. At runtime the encoded chain has already been resolved,
            // so the __auth_got ABI schema is used to re-sign each patched slot.
            image_uses_chained_fixups = YES;
        }
        command_cursor += command->cmdsize;
    }

    if (!symtab_command || !dysymtab_command || !linkedit_segment) {
        return;
    }

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
    nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_command->symoff);
    char *strtab = (char *)(linkedit_base + symtab_command->stroff);
    uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_command->indirectsymoff);

    command_cursor = (uintptr_t)header + sizeof(mach_header_t);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        struct load_command *command = (struct load_command *)command_cursor;
        if (command->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            segment_command_t *segment = (segment_command_t *)command;
            BOOL is_data_segment =
                strcmp(segment->segname, SEG_DATA) == 0 ||
                strcmp(segment->segname, "__DATA_CONST") == 0;
            if (is_data_segment) {
                for (uint32_t section_index = 0; section_index < segment->nsects; section_index++) {
                    section_t *section = (section_t *)((uintptr_t)segment + sizeof(segment_command_t)) + section_index;
                    uint32_t type = section->flags & SECTION_TYPE;
                    if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS) {
                        apt_perform_rebinding_with_section(rebindings,
                                                           section,
                                                           slide,
                                                           symtab,
                                                           strtab,
                                                           indirect_symtab,
                                                           image_uses_chained_fixups);
                    }
                }
            }
        }
        command_cursor += command->cmdsize;
    }
}

static void apt_dyld_image_added(const struct mach_header *header, intptr_t slide) {
    if (gRebindingsHead) {
        apt_rebind_symbols_for_image(header, slide, gRebindingsHead);
    }
}

static int apt_rebind_symbols(struct APTRebinding rebindings[], size_t count) {
    int failure = apt_prepend_rebindings(&gRebindingsHead, rebindings, count);
    if (failure < 0) {
        return failure;
    }

    if (!gDyldCallbackRegistered) {
        // Registration synchronously invokes the callback for every image that
        // is already loaded, then covers frameworks loaded later via dlopen.
        gDyldCallbackRegistered = YES;
        _dyld_register_func_for_add_image(apt_dyld_image_added);
    } else {
        // A later rebinding registration must also be applied to existing
        // images because dyld only calls add-image callbacks once per image.
        for (uint32_t image_index = 0; image_index < _dyld_image_count(); image_index++) {
            apt_rebind_symbols_for_image(_dyld_get_image_header(image_index),
                                         _dyld_get_image_vmaddr_slide(image_index),
                                         gRebindingsHead);
        }
    }

    return 0;
}

@interface APTObjCMsgSendHook : NSObject
@end

@implementation APTObjCMsgSendHook

+ (void)load {
    if (apt_bool_from_environment(@"APPLETRACE_AUTO_HOOK_OBJC_MSGSEND", NO)) {
        apt_install_objc_msgsend_hook();
    }
}

@end

BOOL APTInstallObjcMsgSendHook(void) {
    return apt_install_objc_msgsend_hook();
}

BOOL APTIsObjcMsgSendHookInstalled(void) {
    return gHookInstalled;
}

void APTSetObjcTraceClassFilters(const char *allow_prefixes, const char *deny_prefixes) {
    char **new_allow = NULL;
    size_t new_allow_count = 0;
    char **new_deny = NULL;
    size_t new_deny_count = 0;
    apt_parse_prefix_string(allow_prefixes, &new_allow, &new_allow_count);
    apt_parse_prefix_string(deny_prefixes, &new_deny, &new_deny_count);

    os_unfair_lock_lock(&gInternLock);
    char **old_allow = gAllowPrefixes;
    size_t old_allow_count = gAllowPrefixCount;
    char **old_deny = gDenyPrefixes;
    size_t old_deny_count = gDenyPrefixCount;
    gAllowPrefixes = new_allow;
    gAllowPrefixCount = new_allow_count;
    gDenyPrefixes = new_deny;
    gDenyPrefixCount = new_deny_count;
    gFilterGeneration += 1;
    os_unfair_lock_unlock(&gInternLock);

    // Prefix arrays are only read while gInternLock is held by the intern/name
    // path, so they are no longer reachable after the swap. Interned names are
    // deliberately retained because active per-thread stacks may still borrow
    // pointers created by an older filter generation.
    apt_free_prefix_list(old_allow, old_allow_count);
    apt_free_prefix_list(old_deny, old_deny_count);
}

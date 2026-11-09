//
//  appletrace_hook.m
//  Compiles the objc_msgSend hook into the SwiftPM C target.
//
//  Like appletrace_impl.mm, this pulls in the canonical source from the Xcode
//  framework tree so both build systems share one copy. On architectures other
//  than arm64 / arm64e the hook compiles to a stub that reports failure.
//

#include "../../appletrace/appletrace/src/objc/hook_objc_msgSend.m"

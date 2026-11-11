//
//  appletrace_impl.mm
//  Compiles the AppleTrace core into the SwiftPM C target.
//
//  Rather than duplicate the implementation, this pulls in the canonical
//  source from the Xcode framework tree so both build systems share one copy.
//  The objc_msgSend hook is compiled alongside it (appletrace_hook.m).
//

#include "../../appletrace/appletrace/src/appletrace.mm"

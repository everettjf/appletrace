//
//  AppleTrace.swift
//  Idiomatic Swift surface over the AppleTrace C core, plus the tracing macros.
//
//  Why this exists: the automatic objc_msgSend hook only sees Objective-C
//  dynamic dispatch, so most Swift calls (static / vtable / witness dispatch)
//  are invisible to it. Instrumenting Swift at the source level — via these
//  wrappers and the @Traced / @TraceAll macros — sidesteps dispatch entirely:
//  the begin/end calls are emitted into the function body at compile time, so
//  they work for final classes, structs, and protocol methods alike.
//
//  Names passed as string literals bind to the `StaticString` overloads, which
//  hand the literal's storage straight to the C core (no bridging, no
//  allocation). Dynamic `String` names still work through the `String`
//  overloads.
//

import CAppleTrace

// MARK: - Manual API

/// Begins an async span, recording the current Swift task's name (Swift 6.2
/// `Task(name:)` / `addTask(name:)`, OS 26 and later) as its `task` argument.
@usableFromInline
func asyncBeginRecordingTask(_ name: UnsafePointer<CChar>, _ id: UInt64) {
    #if compiler(>=6.2)
    if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *), let task = Task.name {
        task.withCString { APTAsyncBeginWithTask(name, id, $0) }
        return
    }
    #endif
    APTAsyncBegin(name, id)
}

@usableFromInline
@inline(__always)
func cString(_ name: StaticString) -> UnsafePointer<CChar> {
    // String-literal StaticStrings are always pointer-backed and NUL-terminated.
    UnsafeRawPointer(name.utf8Start).assumingMemoryBound(to: CChar.self)
}

/// Begins a trace section. Pair with ``endSection(_:)-(StaticString)`` on the
/// same thread. Prefer ``withSpan(_:_:)-(StaticString,_)`` or the ``Traced()``
/// macro, which can't leak a missing end.
@inlinable
public func beginSection(_ name: StaticString) {
    APTBeginSection(cString(name))
}

/// Begins a trace section with a dynamically built name.
@inlinable
@_disfavoredOverload
public func beginSection(_ name: String) {
    APTBeginSection(name)
}

/// Ends a trace section previously opened with `beginSection`.
@inlinable
public func endSection(_ name: StaticString) {
    APTEndSection(cString(name))
}

/// Ends a trace section with a dynamically built name.
@inlinable
@_disfavoredOverload
public func endSection(_ name: String) {
    APTEndSection(name)
}

/// Runs `body` inside a trace section named `name`, closing the section even if
/// `body` throws or returns early. For `async` work use
/// ``withAsyncSpan(_:_:)-(StaticString,_)``: a section must begin and end on the
/// same thread, and an `await` may resume on another one.
@inlinable
public func withSpan<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
    APTBeginSection(cString(name))
    defer { APTEndSection(cString(name)) }
    return try body()
}

/// ``withSpan(_:_:)-(StaticString,_)`` for a dynamically built name.
@inlinable
@_disfavoredOverload
public func withSpan<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
    APTBeginSection(name)
    defer { APTEndSection(name) }
    return try body()
}

/// Runs async `body` inside an async span, which Perfetto draws on its own
/// track and which may begin and end on different threads. The span records
/// the current task's name, if it has one, as its `task` argument.
@inlinable
public func withAsyncSpan<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
    let id = APTNewAsyncID()
    asyncBeginRecordingTask(cString(name), id)
    defer { APTAsyncEnd(cString(name), id) }
    return try await body()
}

/// ``withAsyncSpan(_:_:)-(StaticString,_)`` for a dynamically built name.
@inlinable
@_disfavoredOverload
public func withAsyncSpan<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
    let id = APTNewAsyncID()
    name.withCString { asyncBeginRecordingTask($0, id) }
    defer { APTAsyncEnd(name, id) }
    return try await body()
}

/// Emits an instantaneous marker at the current time.
@inlinable
public func traceInstant(_ name: StaticString) {
    APTInstant(cString(name))
}

@inlinable
@_disfavoredOverload
public func traceInstant(_ name: String) {
    APTInstant(name)
}

/// Emits a counter sample that Perfetto renders as a graph track.
@inlinable
public func traceCounter(_ name: StaticString, _ value: Double) {
    APTCounter(cString(name), value)
}

@inlinable
@_disfavoredOverload
public func traceCounter(_ name: String, _ value: Double) {
    APTCounter(name, value)
}

/// Returns a process-unique id for ``asyncBegin(_:id:)-(StaticString,_)`` /
/// ``asyncEnd(_:id:)-(StaticString,_)`` pairs.
@inlinable
public func newAsyncID() -> UInt64 {
    APTNewAsyncID()
}

/// Begins an async span identified by `(name, id)`; it may end on another thread.
@inlinable
public func asyncBegin(_ name: StaticString, id: UInt64) {
    APTAsyncBegin(cString(name), id)
}

@inlinable
@_disfavoredOverload
public func asyncBegin(_ name: String, id: UInt64) {
    APTAsyncBegin(name, id)
}

/// Ends the async span identified by `(name, id)`.
@inlinable
public func asyncEnd(_ name: StaticString, id: UInt64) {
    APTAsyncEnd(cString(name), id)
}

@inlinable
@_disfavoredOverload
public func asyncEnd(_ name: String, id: UInt64) {
    APTAsyncEnd(name, id)
}

/// Flushes buffered events to disk. The runtime also drains in the
/// background (every second by default, see `APPLETRACE_FLUSH_INTERVAL_MS`),
/// when the app enters the background, and at exit; call this before reading
/// the trace in-process.
@inlinable
public func flush() {
    APTFlush()
}

/// Enables or disables recording at runtime.
@inlinable
public func setEnabled(_ enabled: Bool) {
    APTSetEnabled(enabled ? true : false)
}

/// Whether recording is currently enabled.
@inlinable
public var isEnabled: Bool {
    APTIsEnabled()
}

/// The directory trace fragments are written to.
@inlinable
public var traceDirectory: String {
    String(cString: APTGetTraceDirectory())
}

/// Installs the automatic `objc_msgSend` hook (arm64 / arm64e only), tracing
/// every Objective-C message send. Returns `false` where the hook is
/// unavailable. Equivalent to launching with
/// `APPLETRACE_AUTO_HOOK_OBJC_MSGSEND=1`.
@discardableResult
@inlinable
public func installObjCMsgSendHook() -> Bool {
    APTInstallObjcMsgSendHook()
}

/// Whether the `objc_msgSend` hook is installed.
@inlinable
public var isObjCMsgSendHookInstalled: Bool {
    APTIsObjcMsgSendHookInstalled()
}

// MARK: - Macro support (not public API)

/// Called by ``Traced()``-generated code for synchronous functions.
@inlinable
public func _tracedBegin(_ name: StaticString) {
    APTBeginSection(cString(name))
}

/// Called by ``Traced()``-generated code for synchronous functions.
@inlinable
public func _tracedEnd(_ name: StaticString) {
    APTEndSection(cString(name))
}

/// Called by ``Traced()``-generated code for `async` functions.
@inlinable
public func _tracedAsyncBegin(_ name: StaticString) -> UInt64 {
    let id = APTNewAsyncID()
    asyncBeginRecordingTask(cString(name), id)
    return id
}

/// Called by ``Traced()``-generated code for `async` functions.
@inlinable
public func _tracedAsyncEnd(_ name: StaticString, _ id: UInt64) {
    APTAsyncEnd(cString(name), id)
}

// MARK: - Macros

/// Wraps the annotated function's body in a trace span named after the
/// function, qualified by its enclosing type (for example
/// `FeedViewModel.reload(force:)`). Works regardless of how the method is
/// dispatched.
///
/// Synchronous functions get a section (`B`/`E`). `async` functions get an
/// async span (`b`/`e`) instead, because an `await` may resume on a different
/// thread and a section must begin and end on the same one; it records the
/// current task's name (Swift 6.2 named tasks, OS 26+) as its `task` argument.
///
/// ```swift
/// @Traced
/// func loadConfig() { /* ... */ }
///
/// @Traced("feed.refresh")
/// func refresh() async throws { /* ... */ }
/// ```
@attached(body)
public macro Traced() = #externalMacro(module: "AppleTraceMacrosPlugin", type: "TracedMacro")

/// ``Traced()`` with an explicit span name.
@attached(body)
public macro Traced(_ name: StaticString) = #externalMacro(module: "AppleTraceMacrosPlugin", type: "TracedMacro")

/// Applies ``Traced()`` to every method and initializer with a body declared
/// directly in the annotated type or extension. Members already marked
/// `@Traced` or `@NotTraced` are left alone.
///
/// ```swift
/// @TraceAll
/// final class FeedViewModel { /* every method is traced */ }
/// ```
@attached(memberAttribute)
public macro TraceAll() = #externalMacro(module: "AppleTraceMacrosPlugin", type: "TraceAllMacro")

/// Excludes a member from ``TraceAll()``. Expands to nothing.
@attached(peer)
public macro NotTraced() = #externalMacro(module: "AppleTraceMacrosPlugin", type: "NotTracedMacro")

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

import CAppleTrace

// MARK: - Manual API

/// Begins a trace section. Pair with ``endSection(_:)`` on the same thread.
/// Prefer ``withSpan(_:_:)`` or the ``Traced()`` macro, which can't leak a
/// missing end.
@inlinable
public func beginSection(_ name: String) {
    APTBeginSection(name)
}

/// Ends a trace section previously opened with ``beginSection(_:)``.
@inlinable
public func endSection(_ name: String) {
    APTEndSection(name)
}

/// Runs `body` inside a trace section named `name`, closing the section even if
/// `body` throws or returns early.
@inlinable
public func withSpan<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
    APTBeginSection(name)
    defer { APTEndSection(name) }
    return try body()
}

/// Emits an instantaneous marker at the current time.
@inlinable
public func traceInstant(_ name: String) {
    APTInstant(name)
}

/// Emits a counter sample that Perfetto renders as a graph track.
@inlinable
public func traceCounter(_ name: String, _ value: Double) {
    APTCounter(name, value)
}

/// Begins an async span identified by `(name, id)`; it may end on another thread.
@inlinable
public func asyncBegin(_ name: String, id: UInt64) {
    APTAsyncBegin(name, id)
}

/// Ends the async span identified by `(name, id)`.
@inlinable
public func asyncEnd(_ name: String, id: UInt64) {
    APTAsyncEnd(name, id)
}

/// Flushes buffered events to disk. Call before reading the trace off-device
/// (the writer batches per thread).
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

public enum CaptureState: UInt32, Sendable {
    case idle = 0
    case starting = 1
    case recording = 2
    case stopping = 3
    case finalizing = 4
}

public struct TraceMetrics: Sendable, Equatable {
    public let acceptedEvents: UInt64
    public let pendingBytes: UInt64
    public let writeFailures: UInt64
}

/// Starts recording if the runtime is idle. Returns true when recording is
/// active after the call, including an already-running capture.
@discardableResult
public func startCapture() -> Bool {
    APTStartCapture()
}

/// Stops recording and synchronously flushes pending trace batches.
public func stopCapture() {
    APTStopCapture()
}

public var captureState: CaptureState {
    CaptureState(rawValue: APTGetCaptureState().rawValue) ?? .idle
}

public var traceMetrics: TraceMetrics {
    var metrics = APTTraceMetrics(accepted_events: 0, pending_bytes: 0, write_failures: 0)
    APTGetTraceMetrics(&metrics)
    return TraceMetrics(
        acceptedEvents: metrics.accepted_events,
        pendingBytes: metrics.pending_bytes,
        writeFailures: metrics.write_failures
    )
}

// MARK: - Macros

/// Wraps the annotated function's body in a trace section named after the
/// function (`#function`, including argument labels). Works regardless of how
/// the method is dispatched.
///
/// ```swift
/// @Traced
/// func loadConfig() { /* ... */ }
/// ```
@attached(body)
public macro Traced() = #externalMacro(module: "AppleTraceMacrosPlugin", type: "TracedMacro")

/// Applies ``Traced()`` to every method with a body declared directly in the
/// annotated type or extension.
///
/// ```swift
/// @TraceAll
/// final class FeedViewModel { /* every method is traced */ }
/// ```
@attached(memberAttribute)
public macro TraceAll() = #externalMacro(module: "AppleTraceMacrosPlugin", type: "TraceAllMacro")

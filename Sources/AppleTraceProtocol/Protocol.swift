import Foundation

public enum AppleTraceProtocolVersion {
    public static let current: UInt32 = 1
}

public struct TraceMetricsPayload: Codable, Equatable, Sendable {
    public var acceptedEvents: UInt64
    public var pendingBytes: UInt64
    public var writeFailures: UInt64

    public init(acceptedEvents: UInt64, pendingBytes: UInt64, writeFailures: UInt64) {
        self.acceptedEvents = acceptedEvents
        self.pendingBytes = pendingBytes
        self.writeFailures = writeFailures
    }
}

public struct AgentStatusPayload: Codable, Equatable, Sendable {
    public var protocolVersion: UInt32
    public var processId: Int32
    public var processName: String
    public var bundleIdentifier: String?
    public var architecture: String
    public var captureState: String
    public var objcHookInstalled: Bool
    public var traceDirectory: String
    public var metrics: TraceMetricsPayload

    public init(
        protocolVersion: UInt32 = AppleTraceProtocolVersion.current,
        processId: Int32,
        processName: String,
        bundleIdentifier: String?,
        architecture: String,
        captureState: String,
        objcHookInstalled: Bool,
        traceDirectory: String,
        metrics: TraceMetricsPayload
    ) {
        self.protocolVersion = protocolVersion
        self.processId = processId
        self.processName = processName
        self.bundleIdentifier = bundleIdentifier
        self.architecture = architecture
        self.captureState = captureState
        self.objcHookInstalled = objcHookInstalled
        self.traceDirectory = traceDirectory
        self.metrics = metrics
    }
}

public struct FilterConfigurationPayload: Codable, Equatable, Sendable {
    public var allowClassPrefixes: [String]
    public var denyClassPrefixes: [String]

    public init(allowClassPrefixes: [String] = [], denyClassPrefixes: [String] = []) {
        self.allowClassPrefixes = allowClassPrefixes
        self.denyClassPrefixes = denyClassPrefixes
    }
}

public struct ArtifactPayload: Codable, Equatable, Sendable {
    public var name: String
    public var size: UInt64
    public var modifiedAt: Date

    public init(name: String, size: UInt64, modifiedAt: Date) {
        self.name = name
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct APIErrorPayload: Codable, Equatable, Sendable {
    public var error: String

    public init(_ error: String) {
        self.error = error
    }
}

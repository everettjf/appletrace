//
//  main.swift
//  `appletrace` — merge, view, and capture AppleTrace traces from the command
//  line. macOS only (it drives devicectl, ssh and the browser).
//

#if os(macOS)
import AppleTraceKit
import Foundation

let usage = """
appletrace — capture AppleTrace traces and open them in Perfetto

USAGE
  appletrace merge <trace-dir> [-o trace.json] [--raw]
  appletrace open <trace-dir | trace.json> [--raw] [--no-browser] [--port 9001]
  appletrace devices
  appletrace pull  --device <udid|name> --bundle-id <id> [-o <dir>]
  appletrace record --device <udid|name> --bundle-id <id> [--duration <sec>]
                    [--hook] [--allow <prefixes>] [--deny <prefixes>] [--text]
                    [--env KEY=VALUE]... [-o <dir>] [--open]
  appletrace jb <subcommand> ...      (jailbroken devices over SSH; see `appletrace jb help`)
  appletrace version

COMMANDS
  merge    Merge trace fragments (text and/or binary) into a Perfetto JSON trace.
           Begin/end pairs become X complete events unless --raw is given.
  open     Merge if needed, then open the trace in ui.perfetto.dev through a
           local hand-off page (the file is passed to the Perfetto tab in your
           browser, never uploaded).
  devices  List iOS devices visible to devicectl.
  pull     Copy <app container>/Library/appletracedata from a development-signed
           app on a device (devicectl).
  record   Launch the app with AppleTrace enabled, wait, stop it, pull and merge
           the trace. --hook turns on the objc_msgSend hook; --allow / --deny
           take comma-separated class-name prefixes.
"""

let toolVersion = "2.0.0"

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Argument parsing

struct Arguments {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ raw: [String], valueOptions: Set<String>, flagOptions: Set<String>) throws {
        var index = 0
        while index < raw.count {
            let item = raw[index]
            if item == "--" {
                positional.append(contentsOf: raw[(index + 1)...])
                break
            }
            if item.hasPrefix("-") && item.count > 1 {
                var name = item
                var inlineValue: String?
                if let equals = item.firstIndex(of: "="), item.hasPrefix("--") {
                    name = String(item[..<equals])
                    inlineValue = String(item[item.index(after: equals)...])
                }
                if flagOptions.contains(name) {
                    flags.insert(name)
                } else if valueOptions.contains(name) {
                    let value: String
                    if let inlineValue {
                        value = inlineValue
                    } else {
                        index += 1
                        guard index < raw.count else { throw CLIError("\(name) needs a value") }
                        value = raw[index]
                    }
                    options[name, default: []].append(value)
                } else {
                    throw CLIError("unknown option \(name)")
                }
            } else {
                positional.append(item)
            }
            index += 1
        }
    }

    func value(_ names: String...) -> String? {
        for name in names {
            if let value = options[name]?.last { return value }
        }
        return nil
    }

    func values(_ name: String) -> [String] { options[name] ?? [] }
    func has(_ name: String) -> Bool { flags.contains(name) }
}

func expandPath(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

// MARK: - Process helpers

@discardableResult
func run(_ executable: String, _ arguments: [String], quiet: Bool = false, input: Data? = nil) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let inputPipe = Pipe()
    if input != nil {
        process.standardInput = inputPipe
    }
    try process.run()
    if let input {
        inputPipe.fileHandleForWriting.write(input)
        inputPipe.fileHandleForWriting.closeFile()
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    if !quiet && process.terminationStatus != 0 {
        FileHandle.standardError.write(Data(output.utf8))
    }
    return (process.terminationStatus, output)
}

func devicectl(_ arguments: [String]) throws -> [String: Any] {
    let jsonURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("appletrace-devicectl-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: jsonURL) }
    let result = try run("/usr/bin/xcrun", ["devicectl"] + arguments + ["--json-output", jsonURL.path], quiet: true)
    let data = (try? Data(contentsOf: jsonURL)) ?? Data()
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    if result.status != 0 {
        let message = ((json["error"] as? [String: Any])?["userInfo"] as? [String: Any])?.description ?? result.output
        throw CLIError("devicectl \(arguments.prefix(3).joined(separator: " ")) failed: \(message)")
    }
    return json
}

struct Device {
    var identifier: String
    var udid: String
    var name: String
    var model: String
    var osVersion: String
    var connected: Bool
    var paired: Bool
}

func listDevices() throws -> [Device] {
    let json = try devicectl(["list", "devices"])
    let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]] ?? []
    return devices.compactMap { device in
        let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
        let properties = device["deviceProperties"] as? [String: Any] ?? [:]
        let connection = device["connectionProperties"] as? [String: Any] ?? [:]
        // Physical iOS devices only; simulators are traced on the Mac directly.
        guard (hardware["platform"] as? String) == "iOS",
              (hardware["reality"] as? String) != "simulated" else { return nil }
        return Device(
            identifier: device["identifier"] as? String ?? "",
            udid: hardware["udid"] as? String ?? "",
            name: properties["name"] as? String ?? "",
            model: hardware["marketingName"] as? String ?? (hardware["productType"] as? String ?? ""),
            osVersion: properties["osVersionNumber"] as? String ?? "",
            connected: (connection["tunnelState"] as? String) == "connected",
            paired: (connection["pairingState"] as? String) == "paired"
        )
    }
}

func resolveDevice(_ query: String?) throws -> Device {
    let devices = try listDevices()
    if let query {
        if let match = devices.first(where: { $0.udid == query || $0.identifier == query || $0.name == query }) {
            return match
        }
        throw CLIError("no device matches \"\(query)\" (see `appletrace devices`)")
    }
    // Prefer a device with an active tunnel; otherwise a paired one that is
    // idle (devicectl reconnects it on demand).
    var candidates = devices.filter(\.connected)
    if candidates.isEmpty {
        candidates = devices.filter(\.paired)
    }
    guard candidates.count == 1, let only = candidates.first else {
        throw CLIError(candidates.isEmpty
            ? "no paired iOS device (connect, unlock and trust it, or pass --device)"
            : "several devices are available (\(candidates.map(\.name).joined(separator: ", "))); pass --device <udid|name>")
    }
    return only
}

// MARK: - Commands

func merge(_ args: Arguments) throws -> MergeSummary {
    guard let input = args.positional.first else { throw CLIError("merge needs a trace directory") }
    let directory = expandPath(input)
    let output = args.value("-o", "--output").map(expandPath)
    let summary = try TraceMerger.merge(
        directory: directory,
        output: output,
        options: MergeOptions(completeEvents: !args.has("--raw"))
    )
    print("Merged \(summary.fragments.count) fragment(s), \(summary.eventCount) events → \(summary.output.path)")
    return summary
}

func openInPerfetto(trace: URL, port: UInt16, openBrowser: Bool) throws {
    let data = try Data(contentsOf: trace)
    let server = try TraceHandoffServer(port: port, traceName: trace.lastPathComponent, body: data)
    print("Serving \(trace.path) at \(server.pageURL)")
    if openBrowser {
        try run("/usr/bin/open", [server.pageURL], quiet: true)
    } else {
        print("Open \(server.pageURL) in your browser to load it into Perfetto.")
    }
    print("Waiting for Perfetto to receive the trace (Ctrl-C to stop)…")
    if server.serveUntilDelivered(timeout: 600) {
        print("Trace handed to Perfetto.")
    } else {
        print("Timed out. Drag \(trace.path) into https://ui.perfetto.dev instead.")
    }
}

func open(_ args: Arguments) throws {
    guard let input = args.positional.first else { throw CLIError("open needs a trace directory or trace.json") }
    var target = expandPath(input)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
        throw CLIError("\(target.path) does not exist")
    }
    if isDirectory.boolValue {
        target = try merge(args).output
    }
    let port = UInt16(args.value("--port") ?? "9001") ?? 9001
    try openInPerfetto(trace: target, port: port, openBrowser: !args.has("--no-browser"))
}

func devices() throws {
    let all = try listDevices()
    if all.isEmpty {
        print("No iOS devices found.")
    }
    for device in all {
        let state = device.connected ? "connected" : (device.paired ? "paired, idle" : "not paired")
        print("\(device.udid)  \(device.name)  (\(device.model), iOS \(device.osVersion), \(state))")
    }
}

func pull(device: Device, bundleID: String, into directory: URL) throws {
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = try devicectl([
        "device", "copy", "from",
        "--device", device.identifier,
        "--domain-type", "appDataContainer",
        "--domain-identifier", bundleID,
        "--source", "Library/appletracedata",
        "--destination", directory.path,
    ])
}

func pullCommand(_ args: Arguments) throws {
    guard let bundleID = args.value("--bundle-id", "-b") else { throw CLIError("pull needs --bundle-id") }
    let device = try resolveDevice(args.value("--device", "-d"))
    let directory = expandPath(args.value("-o", "--output") ?? "appletracedata-\(bundleID)")
    try pull(device: device, bundleID: bundleID, into: directory)
    print("Pulled trace fragments into \(directory.path)")
}

func record(_ args: Arguments) throws {
    guard let bundleID = args.value("--bundle-id", "-b") else { throw CLIError("record needs --bundle-id") }
    let device = try resolveDevice(args.value("--device", "-d"))
    let duration = Double(args.value("--duration") ?? "10") ?? 10

    var environment: [String: String] = ["APPLETRACE_ENABLED": "1"]
    if args.has("--hook") { environment["APPLETRACE_AUTO_HOOK_OBJC_MSGSEND"] = "1" }
    if let allow = args.value("--allow") { environment["APPLETRACE_TRACE_CLASS_ALLOW"] = allow }
    if let deny = args.value("--deny") { environment["APPLETRACE_TRACE_CLASS_DENY"] = deny }
    if args.has("--text") { environment["APPLETRACE_FORMAT"] = "text" }
    for pair in args.values("--env") {
        guard let equals = pair.firstIndex(of: "=") else { throw CLIError("--env expects KEY=VALUE, got \(pair)") }
        environment[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
    }
    let flushMs = Double(environment["APPLETRACE_FLUSH_INTERVAL_MS"] ?? "1000") ?? 1000
    let environmentJSON = String(decoding: try JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys]), as: UTF8.self)

    print("Launching \(bundleID) on \(device.name) for \(Int(duration))s…")
    let launch = try devicectl([
        "device", "process", "launch",
        "--device", device.identifier,
        "--terminate-existing",
        "--environment-variables", environmentJSON,
        bundleID,
    ])
    let pid = ((launch["result"] as? [String: Any])?["process"] as? [String: Any])?["processIdentifier"] as? Int
    Thread.sleep(forTimeInterval: duration)

    // The runtime drains buffered events every APPLETRACE_FLUSH_INTERVAL_MS
    // (and the mapped file survives the process), so wait one interval before
    // stopping the app.
    Thread.sleep(forTimeInterval: max(0.5, flushMs / 1000 + 0.5))
    if let pid {
        _ = try? devicectl(["device", "process", "terminate", "--device", device.identifier, "--pid", String(pid)])
    }

    let directory = expandPath(args.value("-o", "--output") ?? "appletracedata-\(bundleID)")
    try pull(device: device, bundleID: bundleID, into: directory)
    var mergeArgs = args
    mergeArgs.positional = [directory.path]
    mergeArgs.options["-o"] = nil
    mergeArgs.options["--output"] = nil
    let summary = try merge(mergeArgs)
    if args.has("--open") {
        try openInPerfetto(trace: summary.output, port: 9001, openBrowser: true)
    } else {
        print("Open it with: appletrace open \(summary.output.path)")
    }
}

// MARK: - Entry point

setvbuf(stdout, nil, _IOLBF, 0)  // progress lines show up promptly when piped
let rawArguments = Array(CommandLine.arguments.dropFirst())
let command = rawArguments.first ?? "help"
let rest = Array(rawArguments.dropFirst())

do {
    switch command {
    case "merge":
        _ = try merge(Arguments(rest, valueOptions: ["-o", "--output"], flagOptions: ["--raw"]))
    case "open":
        try open(Arguments(rest, valueOptions: ["-o", "--output", "--port"], flagOptions: ["--raw", "--no-browser"]))
    case "devices":
        try devices()
    case "pull":
        try pullCommand(Arguments(rest, valueOptions: ["--device", "-d", "--bundle-id", "-b", "-o", "--output"], flagOptions: []))
    case "record":
        try record(Arguments(
            rest,
            valueOptions: ["--device", "-d", "--bundle-id", "-b", "--duration", "--allow", "--deny", "--env", "-o", "--output"],
            flagOptions: ["--hook", "--text", "--open", "--raw"]
        ))
    case "jb":
        try Jailbreak.main(rest)
    case "version", "--version", "-v":
        print("appletrace \(toolVersion)")
    case "help", "--help", "-h":
        print(usage)
    default:
        throw CLIError("unknown command \"\(command)\"\n\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
#else
print("appletrace runs on macOS only.")
#endif

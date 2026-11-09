//
//  Jailbreak.swift
//  `appletrace jb …` — trace any app on a jailbroken device (rootless or
//  roothide) through the AppleTraceLoader tweak, driven over SSH.
//
//  The loader reads <jbroot>/var/mobile/Library/AppleTrace/<bundle-id>.plist
//  (a dictionary of APPLETRACE_* environment variables) at app launch; when the
//  file exists it applies the variables and loads appletrace.framework. Traces
//  land in the app's own <data container>/Library/appletracedata.
//

#if os(macOS)
import AppleTraceKit
import Foundation

enum Jailbreak {
    static let help = """
    appletrace jb — trace any app on a jailbroken device (rootless or roothide)

    USAGE
      appletrace jb install <package.deb>            [ssh options]
      appletrace jb enable  <bundle-id> [--hook] [--allow <prefixes>] [--deny <prefixes>]
                                        [--text] [--env KEY=VALUE]...  [ssh options]
      appletrace jb disable <bundle-id>                [ssh options]
      appletrace jb list                               [ssh options]
      appletrace jb pull    <bundle-id> [-o <dir>]     [ssh options]
      appletrace jb record  <bundle-id> [--duration <sec>] [enable options] [-o <dir>]
                                        [--device <udid|name>] [--open] [ssh options]

    SSH OPTIONS
      --host <host>     device address (default: $APPLETRACE_SSH_HOST)
      --port <port>     SSH port (default: $APPLETRACE_SSH_PORT or 22)
      --user <user>     SSH user (default: root)

    Install the AppleTraceLoader package first (release asset
    appletrace-loader_<version>_iphoneos-arm64.deb for rootless,
    _iphoneos-arm64e.deb for roothide). `record` enables tracing, relaunches
    the app via devicectl, waits, stops it, pulls and merges the trace.
    """

    struct SSH {
        var host: String
        var port: String
        var user: String

        var destination: String { "\(user)@\(host)" }
        var baseArguments: [String] {
            ["-p", port, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", destination]
        }

        @discardableResult
        func shell(_ script: String) throws -> String {
            let result = try run("/usr/bin/ssh", baseArguments + ["sh -s"], quiet: true, input: Data((jbrootPrelude + script).utf8))
            guard result.status == 0 else {
                throw CLIError("ssh \(destination) failed (\(result.status)):\n\(result.output)")
            }
            return result.output
        }

        func copy(_ local: URL, to remote: String) throws {
            let result = try run("/usr/bin/scp", ["-P", port, "-o", "BatchMode=yes", local.path, "\(destination):\(remote)"], quiet: true)
            guard result.status == 0 else { throw CLIError("scp failed:\n\(result.output)") }
        }
    }

    /// Resolves the jailbreak root on the device: /var/jb on rootless, the
    /// randomized /var/containers/Bundle/Application/.jbroot-XXXX on roothide.
    static let jbrootPrelude = """
    set -e
    if [ -d /var/jb/usr/bin ]; then JBROOT=/var/jb
    else JBROOT=$(ls -d /var/containers/Bundle/Application/.jbroot-* 2>/dev/null | head -n 1)
    fi
    [ -n "$JBROOT" ] || { echo "no jailbreak root found (rootless /var/jb or roothide .jbroot-*)" >&2; exit 3; }
    export PATH="$JBROOT/usr/bin:$JBROOT/bin:$JBROOT/usr/sbin:$JBROOT/sbin:$PATH"
    CONFIG_DIR="$JBROOT/var/mobile/Library/AppleTrace"

    """

    static func ssh(from args: Arguments) throws -> SSH {
        let environment = ProcessInfo.processInfo.environment
        guard let host = args.value("--host") ?? environment["APPLETRACE_SSH_HOST"] else {
            throw CLIError("pass --host <device address> (or set APPLETRACE_SSH_HOST)")
        }
        return SSH(
            host: host,
            port: args.value("--port") ?? environment["APPLETRACE_SSH_PORT"] ?? "22",
            user: args.value("--user") ?? environment["APPLETRACE_SSH_USER"] ?? "root"
        )
    }

    static let sshOptions: Set<String> = ["--host", "--port", "--user"]
    static let enableOptions: Set<String> = ["--allow", "--deny", "--env"]
    static let enableFlags: Set<String> = ["--hook", "--text"]

    static func validBundleID(_ value: String?) throws -> String {
        guard let value, !value.isEmpty,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }) else {
            throw CLIError("expected a bundle identifier (letters, digits, '.', '-', '_')")
        }
        return value
    }

    static func main(_ raw: [String]) throws {
        let subcommand = raw.first ?? "help"
        let rest = Array(raw.dropFirst())
        switch subcommand {
        case "install":
            let args = try Arguments(rest, valueOptions: sshOptions, flagOptions: [])
            try install(args)
        case "enable":
            let args = try Arguments(rest, valueOptions: sshOptions.union(enableOptions), flagOptions: enableFlags)
            let bundleID = try validBundleID(args.positional.first)
            try enable(bundleID, args, ssh: try ssh(from: args))
            print("Tracing enabled for \(bundleID); relaunch the app to start recording.")
        case "disable":
            let args = try Arguments(rest, valueOptions: sshOptions, flagOptions: [])
            let bundleID = try validBundleID(args.positional.first)
            try ssh(from: args).shell("rm -f \"$CONFIG_DIR/\(bundleID).plist\"\n")
            print("Tracing disabled for \(bundleID).")
        case "list":
            let args = try Arguments(rest, valueOptions: sshOptions, flagOptions: [])
            let output = try ssh(from: args).shell("""
            echo "jailbreak root: $JBROOT"
            if [ -d "$CONFIG_DIR" ]; then ls "$CONFIG_DIR" | sed -n 's/\\.plist$//p'; fi
            dpkg-query -W -f='loader: ${Package} ${Version} ${Architecture}\\n' com.everettjf.appletrace-loader 2>/dev/null || echo "loader: not installed"

            """)
            print(output, terminator: "")
        case "pull":
            let args = try Arguments(rest, valueOptions: sshOptions.union(["-o", "--output"]), flagOptions: [])
            let bundleID = try validBundleID(args.positional.first)
            let directory = expandPath(args.value("-o", "--output") ?? "appletracedata-\(bundleID)")
            try pull(bundleID, ssh: try ssh(from: args), into: directory)
            print("Pulled trace fragments into \(directory.path)")
        case "record":
            let args = try Arguments(
                rest,
                valueOptions: sshOptions.union(enableOptions).union(["--duration", "-o", "--output", "--device", "-d"]),
                flagOptions: enableFlags.union(["--open", "--raw"])
            )
            try record(args)
        case "help", "--help", "-h":
            print(help)
        default:
            throw CLIError("unknown jb subcommand \"\(subcommand)\"\n\n\(help)")
        }
    }

    static func install(_ args: Arguments) throws {
        guard let path = args.positional.first else { throw CLIError("install needs a .deb path") }
        let package = expandPath(path)
        let ssh = try ssh(from: args)
        let remote = "/tmp/\(package.lastPathComponent)"
        try ssh.copy(package, to: remote)
        let output = try ssh.shell("""
        dpkg -i "\(remote)"
        rm -f "\(remote)"
        dpkg-query -W -f='installed ${Package} ${Version} (${Architecture})\\n' com.everettjf.appletrace-loader

        """)
        print(output, terminator: "")
    }

    static func enable(_ bundleID: String, _ args: Arguments, ssh: SSH) throws {
        var environment: [String: String] = ["APPLETRACE_ENABLED": "1"]
        if args.has("--hook") { environment["APPLETRACE_AUTO_HOOK_OBJC_MSGSEND"] = "1" }
        if let allow = args.value("--allow") { environment["APPLETRACE_TRACE_CLASS_ALLOW"] = allow }
        if let deny = args.value("--deny") { environment["APPLETRACE_TRACE_CLASS_DENY"] = deny }
        if args.has("--text") { environment["APPLETRACE_FORMAT"] = "text" }
        for pair in args.values("--env") {
            guard let equals = pair.firstIndex(of: "="), pair.hasPrefix("APPLETRACE_") else {
                throw CLIError("--env expects APPLETRACE_KEY=VALUE, got \(pair)")
            }
            environment[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: environment, format: .xml, options: 0)
        let text = String(decoding: plist, as: UTF8.self)
        guard !text.contains("APPLETRACE_PLIST_EOF") else { throw CLIError("invalid --env value") }
        try ssh.shell("""
        mkdir -p "$CONFIG_DIR"
        chmod 755 "$CONFIG_DIR"
        cat > "$CONFIG_DIR/\(bundleID).plist" <<'APPLETRACE_PLIST_EOF'
        \(text)
        APPLETRACE_PLIST_EOF
        chmod 644 "$CONFIG_DIR/\(bundleID).plist"

        """)
    }

    static func pull(_ bundleID: String, ssh: SSH, into directory: URL) throws {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("appletrace-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: archive) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ssh.baseArguments + ["sh -s"]
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: archive)
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data((jbrootPrelude + """
        CONTAINER=""
        for dir in /var/mobile/Containers/Data/Application/*; do
          if grep -q "\(bundleID)" "$dir/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null; then
            CONTAINER="$dir"; break
          fi
        done
        [ -n "$CONTAINER" ] || { echo "no data container for \(bundleID)" >&2; exit 4; }
        [ -d "$CONTAINER/Library/appletracedata" ] || { echo "no trace yet in $CONTAINER/Library/appletracedata" >&2; exit 5; }
        cd "$CONTAINER/Library/appletracedata" && tar -cf - .

        """).utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CLIError("pull failed: \(message)")
        }
        let untar = try run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path], quiet: true)
        guard untar.status == 0 else { throw CLIError("tar failed: \(untar.output)") }
    }

    static func record(_ args: Arguments) throws {
        let bundleID = try validBundleID(args.positional.first)
        let ssh = try ssh(from: args)
        let duration = Double(args.value("--duration") ?? "10") ?? 10
        try enable(bundleID, args, ssh: ssh)

        let device = try resolveDevice(args.value("--device", "-d"))
        print("Launching \(bundleID) on \(device.name) for \(Int(duration))s…")
        let launch = try devicectl([
            "device", "process", "launch", "--device", device.identifier, "--terminate-existing", bundleID,
        ])
        let pid = ((launch["result"] as? [String: Any])?["process"] as? [String: Any])?["processIdentifier"] as? Int
        Thread.sleep(forTimeInterval: duration + 1.5)
        if let pid {
            _ = try? devicectl(["device", "process", "terminate", "--device", device.identifier, "--pid", String(pid)])
        }

        let directory = expandPath(args.value("-o", "--output") ?? "appletracedata-\(bundleID)")
        try pull(bundleID, ssh: ssh, into: directory)
        let summary = try TraceMerger.merge(directory: directory, options: MergeOptions(completeEvents: !args.has("--raw")))
        print("Merged \(summary.fragments.count) fragment(s), \(summary.eventCount) events → \(summary.output.path)")
        if args.has("--open") {
            try openInPerfetto(trace: summary.output, port: 9001, openBrowser: true)
        }
    }
}
#endif

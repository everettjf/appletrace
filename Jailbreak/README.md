# AppleTrace Jailbreak Package

This package is for authorized testing on devices you control. It does not
contain a jailbreak or a new injection engine. A Substrate-compatible injector
(for example ElleKit, libhooker, or Substitute) loads `AppleTraceTweak` into
UIKit processes. The constructor remains inactive unless the current bundle id
is present in the preferences allowlist.

```plist
{
    EnabledBundles = (
        "com.example.MyApp"
    );
}
```

The tweak installs AppleTrace's existing arm64/arm64e Objective-C hook and
connects outward to the local `appletraced` Unix socket. Injected applications
do not listen on TCP ports.

`appletraced` listens only on device loopback at port `31337`, serves the
packaged Web Console, and brokers commands to every connected injected process.
Forward it over USB before opening the console on the host:

```bash
iproxy 31337 31337
```

Read `ControlToken` from
`/var/mobile/Library/Preferences/com.everettjf.appletrace.plist`, then open
`http://127.0.0.1:31337/#token=<ControlToken>`. The browser keeps the token in
session storage and removes it from the visible URL. The console can select a
process, start or stop capture, update filters, and download its traces.

### Stability limits

Production defaults are conservative and can be overridden in the launchd
environment when needed:

| Variable | Default | Purpose |
|---|---:|---|
| `APPLETRACE_AGENT_HEARTBEAT_INTERVAL` | 5 seconds | Agent status heartbeat |
| `APPLETRACE_AGENT_IDLE_TIMEOUT` | 15 seconds | Remove silent Agent sessions |
| `APPLETRACE_AGENT_SEND_TIMEOUT` | 2 seconds | Bound daemon command writes |
| `APPLETRACE_AGENT_MAX_SESSIONS` | 256 | Bound concurrent Agent sockets |
| `APPLETRACE_CONTROL_MAX_CLIENTS` | 32 | Bound concurrent HTTP clients |
| `APPLETRACE_ARTIFACT_QUOTA_BYTES` | 256 MiB | Per-process trace quota |
| `APPLETRACE_ARTIFACT_MAX_FILES` | 128 | Per-process trace-file limit |
| `APPLETRACE_ARTIFACT_SWEEP_INTERVAL` | 30 seconds | Retention sweep cadence |

The daemon removes oldest completed fragments first and always retains at least
the newest trace. HTTP requests also have fixed header, path, body, and idle
limits. Agent reconnects retain a process-level id and increment a connection
counter so transient daemon or socket failures remain visible.

## Build

```bash
cd Jailbreak
make package THEOS_PACKAGE_SCHEME=rootless
make clean
make package THEOS_PACKAGE_SCHEME=
```

The repository-level package gate builds both variants and inspects their
architectures, launchd paths, and packaged Web Console:

```bash
THEOS=/path/to/theos ./scripts/test_jailbreak_packages.sh
```

The package targets iOS 15 or newer and builds arm64 plus arm64e slices. A real
jailbroken device remains required to validate injector compatibility, sandbox
behavior, SpringBoard safety mode, and end-to-end PAC behavior.

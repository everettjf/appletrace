# Control-plane phases and validation

The control plane is delivered in four independently testable phases. Each
phase keeps trace recording inside the existing allocation-light runtime and
moves control work off the trace hot path.

## Phase 1: controllable runtime

The C and Swift APIs expose capture start/stop, capture state, runtime metrics,
flush, and generation-safe class-filter replacement. The hook also observes
images loaded after installation.

Evidence without a phone:

- `swift test` covers lifecycle, disabled tracing, metrics, macros, and protocol
  value round trips.
- `scripts/test_batching_stress.sh` verifies 200,000 paired events in both text
  and binary modes without loss or duplication.
- The standard and experimental simulator scenarios cover nested calls,
  concurrency, super dispatch, ABI-sensitive arguments/returns, and late-loaded
  images.

## Phase 2: embedded control server

`AppleTraceServer` provides a versioned, token-authenticated loopback HTTP and
WebSocket API. It controls capture and filters, reports status, and exposes only
trace artifacts from the configured trace directory. It is opt-in and never
starts automatically.

Evidence without a phone:

- `ProtocolServerTests` exercise authentication, partial HTTP bodies, status
  payloads, WebSocket framing, status streaming, ping/pong, and token strength.
- `swift build --triple arm64-apple-ios15.0 --target AppleTraceServer` verifies
  the iOS cross-build.

## Phase 3: Web Console

The React console is packaged as static resources. In embedded mode it consumes
live WebSocket status; in daemon mode it lists connected processes and scopes
capture commands, filters, metrics, and trace downloads to the selected Agent.

Evidence without a phone:

- `scripts/build_web_console.sh` runs TypeScript checking, frontend tests, a
  production build, and refreshes the embedded resource bundle.
- `scripts/test_jailbreak_control.sh` serves the production bundle and exercises
  two simulated Agents to detect cross-process status, command, or artifact
  mixing.

## Phase 4: jailbreak Agent and daemon

The Theos package contains an allowlist-gated tweak and a root daemon. Injected
processes connect outward over a local Unix socket; `appletraced` owns the
loopback HTTP server and brokers bounded commands to multiple Agent sessions.
Both rootless and rootful layouts contain `arm64` and `arm64e` slices.

Evidence without a phone:

- `scripts/test_jailbreak_ipc.sh` verifies the framed bidirectional command
  protocol.
- `scripts/test_jailbreak_control.sh` verifies authentication, registration,
  process-scoped commands, heartbeats, stale-session eviction, reconnect
  identity, bounded command writes, HTTP input/concurrency limits, artifact
  confinement, and oldest-first quota cleanup.
- `scripts/test_jailbreak_packages.sh` builds and inspects rootless and rootful
  packages, both architecture slices, launchd paths, and Web Console assets.
- The iOS 27 SDK gate builds a genuine `arm64e` app and framework and inspects
  both slices with `lipo`.

## One-command pre-device gate

Run all checks available without a phone:

```bash
./scripts/verify_without_device.sh
```

Include package generation when Theos is installed:

```bash
THEOS=/path/to/theos RUN_THEOS_PACKAGE_TESTS=1 \
  ./scripts/verify_without_device.sh
```

This proves compilation, protocol behavior, host integration, simulator hook
behavior, package layout, and architecture contents. It does not prove code
injection, sandbox behavior, launchd behavior, or PAC execution on a physical
device. Those remaining checks are listed in
[`device-validation.md`](device-validation.md).

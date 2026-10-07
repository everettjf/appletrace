# Device Validation Gates

The first four control-plane phases can be built and exercised without an
iPhone, but the following claims require physical devices.

## Non-jailbroken device

- Build and sign an app containing `AppleTraceServer`.
- Confirm loopback access from mobile Safari while the app is foregrounded.
- Confirm the documented behavior when the app backgrounds or is suspended.
- Repeat text and binary capture tests on a genuine arm64e slice.
- Verify Local Network privacy behavior before enabling an opt-in LAN listener.

## Jailbroken device

- Install both rootless and rootful packages on matching environments.
- Validate at least ElleKit plus one libhooker/Substitute-compatible stack.
- Confirm the tweak is inert when the bundle id is absent from `EnabledBundles`.
- Enable one ordinary test app, restart it, and confirm Agent registration.
- Enable two test apps and confirm the Web Console can select each process
  without mixing status, commands, or artifacts.
- Exercise start, stop, flush, and filter commands over `appletraced`.
- Confirm SpringBoard and unrelated apps remain stable after repeated crashes.
- Verify launchd restart, Agent reconnect, trace ownership, disk quotas, and
  uninstall cleanup.
- Repeat the arm64e ABI suite: nested sends, super dispatch, concurrency, stack
  arguments, floating-point values, and aggregate returns.

Simulator, macOS IPC, cross-compilation, and package inspection are useful
pre-device gates, but they do not replace these checks.

## Complete the pre-device gate

Run the consolidated verifier on an Apple Silicon Mac with Xcode and an iPhone
simulator installed:

```bash
./scripts/verify_without_device.sh
```

It runs the Swift and Python suites, both writer stress modes, the embedded Web
Console build, the complete Agent command round trip, the two-Agent daemon HTTP
control and artifact test, both simulator hook
scenarios, a genuine arm64e compile/slice check with the current iPhoneOS SDK,
and an iOS cross-build of `AppleTraceServer`.

Theos packaging is optional because Theos is not a repository dependency:

```bash
THEOS=/path/to/theos RUN_THEOS_PACKAGE_TESTS=1 \
  ./scripts/verify_without_device.sh
```

To run only the package gate, use:

```bash
THEOS=/path/to/theos ./scripts/test_jailbreak_packages.sh
```

This builds both layouts, checks the `arm64` and `arm64e` slices of the tweak
and daemon, validates the launchd executable path, and confirms that the Web
Console assets are present in each staging tree. CI runs this package gate on
every pull request.

A successful run proves the build, protocol, control, exporter, simulator ABI,
late-image, arm64e compilation, and package-generation gates. It deliberately
does not claim the physical-device behaviors listed above.

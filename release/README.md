# Releases

Release artifacts are attached to GitHub releases
(<https://github.com/everettjf/appletrace/releases>), not committed:

- `appletrace-<version>-macos.zip` — the `appletrace` CLI (universal macOS binary)
- `appletrace.xcframework.zip` — the framework (iOS device, iOS Simulator, macOS)
- `appletrace-loader_<version>_iphoneos-arm64.deb` — jailbreak loader, rootless
- `appletrace-loader_<version>_iphoneos-arm64e.deb` — jailbreak loader, roothide

Build them with `scripts/build_release.sh`.

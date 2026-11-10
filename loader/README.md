# AppleTraceLoader (jailbroken devices)

A tweak that loads AppleTrace into the apps you choose, on **rootless**
(`/var/jb`, e.g. Dopamine) and **roothide** jailbreaks.

- `AppleTraceLoader.m` — the tweak. It derives the jailbreak root from its own
  path (`.jbroot-XXXX` on roothide, `…/procursus` or `/var/jb` on rootless), so
  the same binary works on both. For a launching app it reads
  `<jbroot>/var/mobile/Library/AppleTrace/<bundle-id>.plist`; if present, it
  exports the `APPLETRACE_*` keys it contains and `dlopen`s
  `<jbroot>/Library/Frameworks/appletrace.framework/appletrace`. Apps without a
  config file are untouched.
- `AppleTraceLoader.plist` — injection filter (UIKit apps).
- `control`, `Info.plist` — package and framework metadata templates.

## Build

```bash
brew install ldid xz
./scripts/build_jailbreak_packages.sh
# → build/jailbreak/appletrace-loader_<version>_iphoneos-arm64.deb   (rootless)
# → build/jailbreak/appletrace-loader_<version>_iphoneos-arm64e.deb  (roothide)
```

Both packages contain universal arm64 + arm64e binaries, ad-hoc signed with
`ldid`. No Theos needed.

## Use

```bash
appletrace jb install build/jailbreak/appletrace-loader_2.0.0_iphoneos-arm64e.deb --host <device>
appletrace jb record com.example.App --host <device> --duration 15 --hook --open
```

Only `jb install` needs root. With `mobile`-only SSH (e.g. roothide), install
the `.deb` from Sileo / Zebra and pass `--user mobile` to the other commands.

Each traced app gets `tmp/AppleTraceLoader.log` in its own container with the
jailbreak root, the hook's rebinding diagnostics, and the trace directory;
`appletrace jb pull` prints it.

See the README section "Tracing Any App on a Jailbroken Device".

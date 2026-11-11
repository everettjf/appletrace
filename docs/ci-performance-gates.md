# Performance Gates in CI

Status: new in 2.1. `appletrace summary` turns a trace into per-span timings,
and `appletrace diff` compares them with a baseline and fails the job when a
span got slower. Because AppleTrace records exact begin/end times rather than
samples, a gate can watch the specific spans you care about
(`@Traced` functions, `withSpan` regions) instead of a whole-app number.

## The commands

```bash
# Per-span count, total, self, mean, p50, p95 and max. Each argument is one
# run (a fragment directory or a merged trace JSON); several runs combine.
appletrace summary run1 run2 run3 [--only App.,FeedStore.] [--top 20] [--sort p95]

# Save the summary as a baseline (a small JSON file you can commit).
appletrace summary run1 run2 run3 -o perf/baseline.json

# Compare. Exit status: 0 = no regression, 2 = regression, 1 = error.
appletrace diff perf/baseline.json current.json \
  --metric p50 --threshold 20% --min-delta 2ms --only App.,FeedStore.
```

Each `diff` input can be a trace directory, a merged `trace.json`, or a saved
summary. A span counts as **regressed** when its metric grew by more than
`--threshold` *and* by at least `--min-delta`; as **improved** in the
opposite case. Spans present on only one side are reported as **added** or
**removed**; `--fail-on-missing` makes a removed span fail the check (useful
to catch instrumentation that silently disappeared). `--json` prints a
machine-readable report; `--all` lists unchanged spans too.

| `--metric` | Compares | Good for |
|------------|----------|----------|
| `total` (default) | Sum of all durations | One-off spans such as launch, where call count matters |
| `p50` | Median duration across all runs | Repeated spans; the most noise-resistant |
| `p95`, `max` | Tail durations | Jank-sensitive spans, on quiet machines |
| `mean`, `self` | Average / exclusive time | Spans whose children are gated separately |
| `count` | Number of calls | Catching accidental extra work (`--min-delta` is a call count) |

## Recording traces on the Simulator

Launch the app with `simctl`, let it run, stop it and copy
`Library/appletracedata` out of its data container. The runtime drains its
buffers every second, so the trace is complete once the app has been running
for longer than your scenario plus a second.

```bash
APP_ID=com.example.MyApp
APP=build/Build/Products/Debug-iphonesimulator/MyApp.app
SIM="$(xcrun simctl create appletrace-ci "iPhone 17")"
xcrun simctl boot "$SIM"
xcrun simctl bootstatus "$SIM"
xcrun simctl install "$SIM" "$APP"
mkdir -p traces
for run in 1 2 3; do
  # Environment for the app: SIMCTL_CHILD_<NAME>. Add your own switch that
  # drives the scenario you want to measure.
  SIMCTL_CHILD_MYAPP_PERF_SCENARIO=1 \
    xcrun simctl launch --terminate-running-process "$SIM" "$APP_ID"
  sleep 8
  xcrun simctl terminate "$SIM" "$APP_ID"
  cp -R "$(xcrun simctl get_app_container "$SIM" "$APP_ID" data)/Library/appletracedata" "traces/run$run"
done
xcrun simctl delete "$SIM"
```

Build the app with `-destination 'generic/platform=iOS Simulator'`, not
`-sdk iphonesimulator`: forcing the SDK also builds the `@Traced` macro plugin
(a host tool) for the Simulator, and the build fails with "produced malformed
response".

## A GitHub Actions job

```yaml
jobs:
  perf-gate:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build the appletrace CLI
        run: |
          git clone --depth 1 --branch v2.1.0 https://github.com/everettjf/appletrace.git "$RUNNER_TEMP/appletrace"
          swift build -c release --product appletrace --package-path "$RUNNER_TEMP/appletrace"
          echo "$RUNNER_TEMP/appletrace/.build/release" >> "$GITHUB_PATH"

      - name: Build the app for the Simulator
        run: |
          xcodebuild -scheme MyApp -destination 'generic/platform=iOS Simulator' \
            -derivedDataPath build build

      - name: Record three runs
        run: ./scripts/record_perf_runs.sh   # the loop above

      - name: Compare with the committed baseline
        run: |
          appletrace summary traces/run* --only MyApp. -o current.json
          appletrace diff perf/baseline.json current.json \
            --metric p50 --threshold 20% --min-delta 2ms --only MyApp.

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: appletrace-traces
          path: |
            traces
            current.json
```

To create or refresh the baseline, run the same steps on your main branch and
commit `current.json` as `perf/baseline.json` (for example from a manually
triggered workflow). Keep the uploaded traces: `appletrace open traces/run1`
shows exactly what got slower.

## Keeping the gate stable

Hosted macOS runners are shared machines, and wall-clock spans vary with their
load. In our own test on the Swift demo app, three runs recorded while another
build was running had spans several times slower than on an idle machine, while
three runs against three runs on an idle machine compared clean with the
settings below.

- Record **several runs on each side** (at least three) and compare `p50`.
- Gate only **your own spans** with `--only`; automatic `objc_msgSend` traces
  contain thousands of tiny framework calls.
- Use a **generous threshold** (15–25%) and a **minimum delta** of a few
  milliseconds, so a 300 µs span can't fail the build.
- Record the baseline on the **same runner type and Simulator model** as the
  check.
- Use `--metric count` to catch extra work independently of timing noise.

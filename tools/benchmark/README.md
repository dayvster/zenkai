# Startup benchmark

The runner and work summarizer use Zig 0.17. Run from the repository root.
To summarize measured non-Qt work:

```sh
zig run tools/benchmark/startup.zig -- --summarize-work benchmark-results/linux-startup.json
```

The runner exclusively reserves a sibling `.apps-cache` file and removes only
that file on completion or failure. Choose a new output filename for each run.
Metadata includes the Zig version and creation time as Unix milliseconds.
Seeded ordering is reproducible within this runner; it does not reproduce the
older runner's shuffle sequence.

This suite measures a real Qt Widgets window in a desktop session. It does not
claim to measure compositor presentation, monitor scanout, hotkey dispatch, or
hardware input latency. The startup instrumentation is opt-in; normal launches
keep their existing workload and scheduling.

## Build and run

Use Zig 0.17.0 and the project's Qt dependencies. The checked-in build selects
ReleaseFast. Build once, then stop build/test jobs before measuring.

Linux:

```sh
zig build
zig run tools/benchmark/startup.zig -- \
  --binary ./zig-out/bin/zenkai \
  --runs 20 --warmups 3 \
  --output benchmark-results/linux-startup.json \
  --note 'CPU; distro; Qt version; desktop/compositor; refresh rate; power profile; compositor effects setting'
```

Windows (PowerShell):

```powershell
zig build deploy-windows -Dtarget=x86_64-windows-gnu
zig run tools/benchmark/startup.zig -- --binary zig-out/bin/zenkai.exe --runs 20 --warmups 3 --output benchmark-results/windows-startup.json --note 'CPU; Windows version; Qt version; refresh rate; power profile'
```

Run in a real local desktop session. Keep the machine otherwise idle and do not
interact with the windows during the run. They appear and close automatically.
Do not use Qt's offscreen/minimal platform plugin, a hidden window, or Xvfb for
user-facing startup claims. A remote session is a different test environment.

The mode disables zenkai's fade and backdrop and Qt UI effects. On Windows it
requests `DWMWA_TRANSITIONS_FORCEDISABLED` for this window only and records whether
that succeeded. It does not change global Windows preferences. On Linux, disable
window opening/fading effects for zenkai in your compositor if you want a run
without those effects, and record the setting. There is no portable Qt switch
that turns off every Linux compositor's animations. The benchmark still measures
application paint completion, not when the compositor presents it.

Do not run two copies of the suite at the same time. Send the resulting JSON and
its sibling `.patch` file back with your hardware/display notes. Files under
`benchmark-results/` are ignored by Git. The JSON contains local paths, source
snapshots, and raw logs; review it before publishing it publicly.

## What each number means

All internal `*_ms` milestones are cumulative from the first statement in
`main()`, except durations explicitly identified below. The Windows clock uses
QueryPerformanceCounter. Linux uses CLOCK_MONOTONIC.

- `config_ms`: arguments, locale and configuration setup complete.
- `qt_theme_ms`: Qt construction, theme and icon-theme setup complete.
- `plugins_ms`: plugin setup and startup hooks complete.
- `window_ms`: widget construction complete, before benchmark attachment/cache loading.
- `show_return_ms`: the show/raise/focus calls have returned. This is not a completed paint.
- `first_paint_start_ms` / `first_paint_ms`: start/end of the first list viewport
  paint handler. Its list may still be empty or use stale cached entries.
- `data_ready_ms`: the final application list is installed; if a refresh was
  required, this follows its cache write. This is not a paint timestamp.
- `ready_paint_start_ms` / `ready_paint_ms`: start/end of the first viewport paint
  after the final data-ready milestone. For a stale cache, this intentionally
  waits for the refreshed list; it is not time to the first usable cached list.
- `refresh_ms`: discovery, list replacement/filtering and cache serialization;
  excludes the initial 50ms deferred timer wait and subsequent painting.
- `paint_handler_ms`: accumulated time within observed viewport paint handlers.
- `icon_ms`: accumulated decoration-role callbacks in the list model, including
  conversion/cleanup. QIcon can do additional work when painting; this field is
  not the whole icon cost. `icon_requests` counts those callbacks with icons on.
- `parent_observed_ready_ms`: The runner's monotonic clock immediately before spawning the process
  to receipt of the ready JSON line. Includes OS process creation, dynamic loader,
  reporting, pipe transport and reader scheduling. It is an upper observation of
  application readiness, not a pure process-start or pixel-presentation timestamp.
- `input_focused`: whether the search field has Qt focus when the report is sent.
  This is not proof of a physical keyboard event being processed.

Paint timestamps are captured inside QApplication.notify, immediately after
calling its normal implementation exactly once. Only reporting and exit use a
zero-delay timer. This avoids the earlier event-filter design's bug where a
refresh timer could run before the timestamp callback. Schema 1 results from
that experimental design are invalid for first-paint comparisons. Use schema 3.

No benchmark logging happens per paint/icon request. Counters and timestamps are
kept in memory and emitted once. Instrumentation has nonzero overhead: additional
notify dispatch and clock reads. Compare only equally instrumented runs and use
ordinary-launch logs as an independent sanity check.

## Workloads

The runner fixes the theme to `dark` and dimensions to 600x500 (Run mode itself
sets height to 140). Existing configuration can still affect other presentation
settings; record it when comparing machines. It does not rewrite your config.

- `minimal`: no desktop applications, plugins or icons; window-only workload.
- `uncached`: no zenkai application-cache file, plugins off. **Not an OS-cold run.**
- `cached`: a fresh snapshot of the discovered application list, plugins off.
- `cached-no-icons`: the same snapshot, with icon loading disabled.
- `stale`: the same snapshot with an old mtime; paints cached entries and refreshes.
- `cached-plugins`: fresh snapshot, plugin loading permitted. Inspect `plugins`;
  zero means this machine did not exercise a loaded-plugin workload.
- `run`: Windows-only Run dialog. No desktop discovery or plugin setup.

A dedicated temporary cache path is passed in `ZENKAI_BENCHMARK_CACHE`. Ordinary
config, frequency data and application discovery locations remain in place.
Benchmark mode never reads/writes the ordinary app-cache file and skips saving
frequency data. Plugin startup hooks, when enabled, still execute normally.

The suite seeds one snapshot, warms each scenario, then measures 20 runs per
scenario in interleaved, seeded-random order. It retains every sample, including
warmups, but excludes warmups from statistics. P95 uses the nearest-rank method.
No outliers are removed. Cache expectations, process exit, report status and
Windows transition suppression are checked. A failed run aborts and saves its
partial results instead of quietly disappearing from the sample.

For narrower runs, repeat `--scenario`, for example:

```sh
zig run tools/benchmark/startup.zig -- --binary ./zig-out/bin/zenkai \
  --scenario cached --scenario cached-no-icons --runs 30 --warmups 5 \
  --output benchmark-results/linux-icons.json
```

For a true cold-OS test, establish and document a separate reboot/cache protocol.
This runner deliberately does not flush filesystem caches or change power settings.

## Validation

```sh
zig build test-benchmark
zig build test
```

Windows validation on 2026-10-02: the benchmark flag test and statistics
tests pass. The full Zig suite has three existing failures (localized Name,
Exec quoting, literal percent handling), reproduced from an untouched archive
of commit 424de1bc10ba95e5bc9930b1ebbc28c943b3fcf7. They are not changed here.

References: [Qt notify](https://doc.qt.io/qt-6/qcoreapplication.html#notify),
[Qt paint events](https://doc.qt.io/qt-6/qwidget.html#paintEvent),
[Windows window attributes](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute).

## Deferred plugins and visible icons

With deferred loading, `plugins_ms` and `plugins` describe the pre-window manager setup stage, not completion of post-paint discovery or lazy activation. A zero count at this stage does not mean plugins are disabled. The startup suite does not measure first-use plugin latency.

The Windows visible-icon run is saved in `benchmark-results/windows-visible-icons-2026-10-03.json` (20 measured runs per scenario, three warmups). It measures a real window with 121 cached applications and plugins disabled. Median completed first viewport paint: 270.88 ms with icons; 57.39 ms without. These are paint-handler milestones, not compositor presentation times. The earlier icon-enabled run was about 282.7 ms; it was not a paired A/B run, so this does not establish a precise speedup. Offscreen UI tests separately verify that layout loads zero icons and scrolling resolves new icons.

Focused checks: `zig build test-plugins test-ui` (add `-Dtarget=x86_64-windows-gnu` on Windows). UI tests use the offscreen Qt backend for behavior only; performance runs must continue using a real window.

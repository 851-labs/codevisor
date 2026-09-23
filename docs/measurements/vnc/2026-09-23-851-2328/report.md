# 851-2328: `bun run vnc:validate` — notes

`validate.md` beside this file is the gate's own output for this change:
PASS on all four layers (tests 250 + 92, interop 3/3, bench no regression,
tophat 24/24).

## What the first runs found

- **Test totals:** one `swift test` prints a "Test run with N tests" line per
  test binary; the first summary read only the last one. `testCount` now
  totals them.
- **False CPU regressions:** on an unchanged build, client CPU per update on
  `wan150` read +13 % and +19 % at load average ≈ 7 while other metrics
  "improved" by similar amounts. On high-latency profiles that metric is
  mostly idle overhead shared by few updates, so its noise band minimum is now
  25 % (others stay at 10 %); the −80 % target of 851-2319 is still detected.
  Reports now record the load average and flag a busy machine.
- **A benchmark hang:** `Process.waitUntilExit()` called from a Swift
  concurrency thread never returned after the scene server exited (it waits
  on a run loop those threads don't service). The server's exit is now
  observed through its termination handler, and every run has a 3-minute
  watchdog so a stall fails instead of blocking the gate.

## Acceptance criteria

- One command, one report: `bun run vnc:validate --issue 851-XXXX` runs the
  VNC Swift suites and the rig package's tests, `vnc:interop`, `vnc:bench`
  against the baseline and `vnc:tophat`, writes
  `docs/measurements/vnc/<date>-<issue>/validate.md`, and exits non-zero on
  any failure or out-of-noise regression.
- `--skip`, `--swift-filter`, `--bench`, `--machines`, `--save-baseline`.
- Docs and the `vnc-change` skill describe the command, the `Validation:`
  trailer pointing at `validate.md`, and landing through a pull request.

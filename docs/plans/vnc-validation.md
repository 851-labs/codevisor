# VNC validation

How every VNC change is tested and measured before it is called done. It
applies to the "Great VNC experience" project (Linear 851-2308) and to any
later change under `packages/swift/ScreenSharing/Sources/ScreenSharing/RFB`,
`.../VNC`, `RFBWebSocketTransport`, the server's VNC socket route or
`scripts/vnc-desktop.sh`. The `vnc-change` skill loads this document for that
work. Follows `docs/plans/vnc-viewer.md` and `docs/plans/screen-sharing-vps.md`.

## Principles

- A change is done when it is shown to be correct at every layer it touches
  and its performance effect is measured, not when it builds.
- Correctness tests are deterministic (see the `deterministic-tests` skill):
  no sleeps, real clocks or fixed ports. Wall-clock performance lives in the
  benchmark, never in correctness tests. Counts (bytes copied, bytes moved,
  messages sent) are deterministic and belong in tests.
- The reference server implements every feature the client advertises. It is
  the oracle for tests, the workload for the benchmark and the Loopback
  server machine in the rig.
- One command produces the evidence: `bun run vnc:validate`.

## Correctness: four layers

| Layer | What                                                                                                                                                                                                                                  | Where                                                                                | When                                      |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | ----------------------------------------- |
| L1    | Protocol units: decode known bytes to exact pixels; malformed input throws `RFBError` and never crashes or over-reads; seeded generated inputs; fixtures recorded from real servers                                                   | `ScreenSharingTests/RFB`, `ScriptedTransport`/`RFBScript`                            | Every commit (pre-commit)                 |
| L2    | In-process end to end against `RFBLoopbackServer`: client framebuffer equals the server's (exact for lossless, PSNR threshold for JPEG); the client's message log is exact; operation counts bounded; network shaping on a test clock | `ScreenSharingTests/RFB`, `ScreenSharingTests/VNC`, `CodevisorCoreMacTests` (`.vnc`) | Every commit (pre-commit)                 |
| L3    | Real servers: pinned TigerVNC Xvnc container with a scripted desktop (optionally x11vnc); env-gated interop suites                                                                                                                    | `bun run vnc:interop`                                                                | Before closing a ticket; part of validate |
| L4    | The product path in the rig: open a machine, View/Control, type, clipboard both ways, resize; window-only screenshots                                                                                                                 | Scripted rig tophat against Loopback server and Contabo VPS                          | Before closing a ticket                   |

Rules:

- Write the failing L1 or L2 test before the implementation.
- A feature adds its server side to `RFBLoopbackServer` in the same change.
  The parity test fails when the client advertises an encoding or extension
  the reference server lacks.
- A behaviour seen only on a real server is recorded (wire recorder) and
  becomes an L1 fixture, so the regression test runs without that server.
- L3 and L4 never replace L1/L2: if a bug is only caught by L3, add the
  missing lower-layer test.

## Performance: `vnc-bench`

The benchmark is a rig subcommand (`screen-sharing-rig vnc-bench`), separate
from the tests. `bun run vnc:bench` builds it in release mode, writes
`tmp/vnc-bench/<time>/bench.{json,md}` and compares with this machine's
baseline; `--save-baseline` replaces the baseline, `--scenes`, `--profiles`,
`--runs`, `--frames` and `--size` narrow or change the matrix.

- **Scenes** (reference server, defined by seed and frame count): idle,
  typing, scroll, window drag, photo/video, resize.
- **Network profiles** (shaping transport): `lan`, `wan40` (40 ms RTT),
  `wan150` (150 ms RTT), `constrained` (150 ms, 10 Mbit/s). Contabo VPS is the
  real-world confirmation, reported separately.
- **Metrics:** updates/s, update latency (request or change → applied),
  input-to-update latency (the server paints a marker on a pointer event; both
  timestamps are taken in one process), bytes on the wire, client CPU per
  update, bytes copied per update, presented fps.
- **Statistics:** N runs per scene and profile; median and p95. An A/A run
  (same build twice) sets the noise band per metric: the larger of both
  sides' run spread and 10 %, and at least a per-metric absolute floor
  (1 ms for latencies). A change is a regression when a metric is worse by
  more than the noise band.
- **Baselines:** `docs/measurements/vnc/baseline-<machine>.json`, updated only
  by a ticket that improves a metric, in the same commit. Reports record the
  hardware, macOS version, build hash and power state; run on AC power with no
  other heavy load.

## Definition of done

For each ticket, in the order the Linear relations allow (a ticket is ready
when everything blocking it is done):

1. The issue states acceptance criteria and a metric target. If it doesn't,
   write them into the issue first.
2. Add the failing L1/L2 test (and the reference server's side).
3. Implement.
4. Run `bun run vnc:validate`: affected Swift suites, `vnc:interop`,
   `vnc-bench` compared with the baseline, and the scripted tophat. It writes
   `docs/measurements/vnc/<date>-<issue>/report.md` and exits non-zero on any
   failure or out-of-noise regression.
5. Commit with the report summary and a `Validation: docs/measurements/vnc/…`
   trailer (the pre-commit suite runs as usual). Post the summary and
   screenshots on the issue, move it to Done, and pick the next ready issue.

Stop and ask instead of continuing when:

- a gate fails for a reason outside the ticket, or a metric outside the
  ticket's scope regresses;
- L3 cannot run (no container runtime, image unavailable) or Contabo is
  unreachable for a ticket whose target needs it;
- the ticket needs a product decision (851-2317, what ⌘ sends);
- meeting the metric target would mean weakening a test, a threshold or a
  baseline.

## Scaffolding

Built before the feature work; every feature issue is blocked by 851-2328.

| Issue    | What                                                                          |
| -------- | ----------------------------------------------------------------------------- |
| 851-2323 | Extensible reference server, scenes, input echo marker, parity test           |
| 851-2324 | Network-shaping transport and profiles                                        |
| 851-2309 | VNC session statistics in Connection Details                                  |
| 851-2310 | `vnc-bench`: scenes × profiles, reports, baselines, noise band                |
| 851-2325 | Pinned Xvnc container and `bun run vnc:interop`                               |
| 851-2326 | Wire recorder: real-server sessions become L1 fixtures                        |
| 851-2327 | Scripted rig tophat (background launch, window-only screenshots)              |
| 851-2328 | `bun run vnc:validate`: one command, one report, non-zero exit on any failure |

Until a scaffolding piece exists, a ticket that needs it is not ready. Build
the missing piece first rather than validating by hand.

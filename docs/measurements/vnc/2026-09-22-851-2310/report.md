# 851-2310: `vnc-bench` — validation

Machine: Apple M4 Max (Mac16,6), macOS 27.2, AC power. Base: `d070e524`.
Release build of the rig; default matrix (typing, scroll, photo, input ×
lan, wan150), 3 runs × 40 frames, 1280 × 800.

| Check                    | Result                                                                                                                     |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| L1 (pure)                | `VNCBenchTests`: 8 tests (statistics, spread, directions, noise band, absolute floors, unmatched cases, JSON, options)     |
| L1 (scripts)             | `scripts/vnc-bench-lib.test.mjs`: 4 tests                                                                                  |
| L2                       | `VNCScreenSharingSessionTests`: the publisher's new `vncBytesCopied` counter is exactly one frame per update today         |
| A/A (same build, 3 runs) | Run 2 vs run 1 at a 5 % floor: 39 within noise, 1 false "improvement" (scroll/lan updates/s +5.4 %) → floor raised to 10 % |
| A/A after the fix        | Run 3 vs run 1: all 40 comparable metrics within noise, no verdicts; exit 0                                                |
| Negative                 | typing/lan at 1920 × 1200 vs the baseline: "copied/update +125 % regressed", exit 1                                        |
| L3 / L4                  | Not applicable: measurement tooling; the client is unchanged apart from one counter                                        |
| Full suite               | Pre-commit hook (includes the rig package's tests)                                                                         |

## Baseline (run 1, now `docs/measurements/vnc/baseline-Mac16_6.json`)

| scene  | profile | updates/s | update p50 ms | update p95 ms | input p50 ms | input p95 ms | bytes/update |    Mbit/s | CPU ms/update | copied/update |
| ------ | ------- | --------: | ------------: | ------------: | -----------: | -----------: | -----------: | --------: | ------------: | ------------: |
| typing | lan     | 288.7 ±3% |      3.34 ±0% |      3.40 ±1% |            – |            – |     63.8 ±0% |  0.15 ±3% |      0.40 ±2% |   4096000 ±0% |
| typing | wan150  |  6.33 ±0% |     156.4 ±0% |     164.5 ±0% |            – |            – |     63.8 ±0% |  0.00 ±0% |     1.73 ±10% |   4096000 ±0% |
| scroll | lan     | 180.4 ±4% |      5.25 ±3% |      6.44 ±6% |            – |            – |    40689 ±0% |  58.7 ±4% |      0.75 ±7% |   4096000 ±0% |
| scroll | wan150  |  5.81 ±1% |     170.7 ±1% |     179.9 ±1% |            – |            – |    40689 ±0% |  1.89 ±1% |      2.86 ±6% |   4096000 ±0% |
| photo  | lan     |  15.4 ±3% |      64.7 ±1% |      65.8 ±8% |            – |            – |  3038227 ±0% | 374.4 ±3% |      8.05 ±6% |   4096000 ±0% |
| photo  | wan150  |  1.32 ±0% |     759.3 ±0% |     770.9 ±1% |            – |            – |  3038227 ±0% |  32.1 ±0% |      30.2 ±4% |   4096000 ±0% |
| input  | lan     |         – |             – |             – |     3.50 ±0% |     3.53 ±0% |            – |         – |             – |             – |
| input  | wan150  |         – |             – |             – |    158.9 ±0% |    166.1 ±1% |            – |         – |             – |             – |

What it already shows, for the feature issues:

- **One update per round trip:** typing and scroll drop from 289 and 180
  updates/s on `lan` to 6.3 and 5.8 on `wan150`, i.e. ≈ 1/RTT; update latency
  p50 ≈ RTT (156 ms). This is the ceiling continuous updates (851-2312) lift.
- **Input latency ≈ one round trip:** 3.5 ms on `lan`, 159 ms on `wan150`
  (pointer echo; no local cursor yet, 851-2311).
- **Whole-frame copies:** 4 096 000 bytes copied per update (the full
  1280 × 800 frame) even for a 64-byte typing update (851-2319).
- **Photo over the WAN:** 3.0 MB per ZRLE update, 1.3 updates/s on `wan150`
  (Tight/JPEG, 851-2313).
- CPU per update is higher on `wan150` than `lan` for the same content: idle
  time between updates is charged to fewer updates (timers, shaping tasks).
  Compare CPU within one profile.

## Acceptance criteria

- **`vnc-bench`:** `screen-sharing-rig vnc-bench` plays each reference scene
  in a separate `vnc-server --scene` process (so this process's CPU is the
  client's), connects the product's `RFBClient` and frame publisher through
  `RFBShapedTransport`, and measures N runs per scene × profile; JSON +
  Markdown with median, noise band, machine and build. `bun run vnc:bench`
  builds in release mode and writes to `tmp/vnc-bench/<time>/`.
- **Metrics:** updates/s, update latency p50/p95, input-to-update latency
  p50/p95 (echo marker), bytes per update, Mbit/s, client CPU ms per update,
  bytes copied per update.
- **Baselines and noise band:** per machine in
  `docs/measurements/vnc/baseline-<model>.json` (`--save-baseline`); the
  comparison uses max(both sides' run spread, 10 %) and per-metric absolute
  floors, and exits 1 on a regression.
- **Real machine:** not included here — the benchmark drives the reference
  server's scenes; Contabo confirmation stays with the feature issues that
  need it.

## Metric target

A/A runs agree within the noise band on every metric: met after raising the
floor to 10 % (run 3 vs run 1).

# 851-2358 — cross-app frame clock: baseline, rig vs Apple Screen Sharing

What a user sees, measured the same way for every viewer. The host (tuftlord,
MacBook Pro 3024×1964, macOS Screen Sharing) shows the frame-clock page full
screen in Safari: a strip of 8 flat-coloured cells carrying the frame number
(1/60 s steps) and a checksum, over full-screen moving noise and shapes
(`mode=video`, a worst case for lossless encodings). On this Mac, the rig and
Apple's Screen Sharing (standard mode, not High Performance) both show tuftlord.
`screen-sharing-rig frame-clock` captures only those two windows at up to 60 fps,
on one clock, and reads the strip in every captured frame.

## Result (video workload, 60 s, both viewers at once)

| viewer               | run | updates/s | gap p50 ms | gap p95 ms | gap max ms | lag behind the other p50 / p95 ms |
| -------------------- | --- | --------: | ---------: | ---------: | ---------: | --------------------------------: |
| Codevisor rig        | 1   |  **0.64** |       1392 |       2430 |       5637 |                    **917 / 2217** |
| Codevisor rig        | 2   |  **0.54** |       1410 |       3074 |      11223 |                   **1083 / 8167** |
| Apple Screen Sharing | 1   |  **5.80** |        142 |        416 |        562 |                                 – |
| Apple Screen Sharing | 2   |  **6.09** |        143 |        291 |        434 |                                 – |

The rig shows about **9–11× fewer frames** than Apple and trails it by about
**1 s** (p50), with stalls of several seconds (11 s in run 2). This matches
Alexandru's side-by-side recording on a YouTube video (1.2 vs 7.6 updates/s,
~0.8 s behind). Run-to-run noise: Apple ±5% updates/s, rig ±16%; the gap is far
outside it.

Torn strips (captured mid-update and rejected by the checksum): rig 0%, Apple
2–16%. Apple sends partial-screen updates more often; a torn capture is never
counted as a frame.

## How to run

```
bun run screen-sharing:rig build --build-only
bun run vnc:frame-clock --label "…" [--mode video|scroll|type|still] [--seconds 60]
```

Open the printed URL on the viewed machine, full screen, then click the page
(or reload it) once the capture is waiting: the strip turns orange for a few
seconds and every window calibrates on it. Only the named windows are captured.

## Harness notes

- Calibration colour is orange (255, 128, 0): a half-on green channel no data
  cell can take. Magenta was first, but it's also a data colour.
- The rig's window is captured in Display P3: sRGB primaries arrive converted,
  e.g. green (0, 255, 0) as (117, 251, 76). The reader's on/off thresholds
  (≥ 165 / ≤ 145) cover that and still reject blurred cell edges.
- The page declares a black theme colour, so Safari doesn't tint its toolbar
  like the strip.
- L1 tests: `FrameClockTests` (code round trip, torn and blurred strips, P3,
  finding the strip beside decoys, statistics), `vnc-frame-clock-lib.test.ts`.

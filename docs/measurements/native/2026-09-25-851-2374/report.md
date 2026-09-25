# 851-2374, part 1: the viewer drew at 36 Hz on a 72 Hz display

## Finding

The native viewer's MTKView asked for `preferredFramesPerSecond = 60`. Its display link only runs at whole fractions of the display's refresh, so on this Mac's 72 Hz LG UltraWide it ran at 36 Hz.

That was the "30 fps ceiling" in the 851-2371 baseline: a flat 34 ms gap, while tuftlord's host was capturing and encoding about 55 fps (1,871 captured and 1,851 encoded in 34 s).

## Fix

The viewer now draws at the smallest whole fraction of its screen's refresh that reaches 60 (72 at 72 Hz, 60 at 120 Hz, 72 at 144 Hz). It follows the window when it moves to another screen.

## Measurements (2026-09-25)

**Loopback, this Mac, in a window on the 72 Hz display** (HEVC 1080p60, 10 s):

|        | decoded | presented/s | callback → presentation p50 / p95 |
| ------ | ------: | ----------: | --------------------------------: |
| before |     558 |        32.9 |                    28.6 / 36.5 ms |
| after  |     573 |    **54.8** |                    30.0 / 36.7 ms |

**Two Macs, frame clock, video, 45 s** (the rig's "tuftlord · High Performance": the app's viewer against Codevisor d6384ccd on tuftlord):

- This Mac was on **Wi-Fi** for these runs, not the wired LAN of the baseline.

|                                | updates/s | gap p50 / p95 ms | image age p50 / p95 ms | Mbit/s |
| ------------------------------ | --------: | ---------------: | ---------------------: | -----: |
| before                         |      34.8 |          34 / 37 |              389 / 468 |   22.0 |
| after                          |  **50.2** |          17 / 35 |          **200 / 227** |   21.9 |
| Apple HP, 851-2371 (wired, 4K) |      48.3 |          18 / 36 |              158 / 228 |     54 |

The remaining gap is image age at p50. The viewer's jitter buffer averages about 124 ms (rig telemetry), and that's what part 2 of 851-2374 is about.

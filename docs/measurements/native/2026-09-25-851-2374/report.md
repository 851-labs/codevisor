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

# Part 2: bounding the receiver's playout delay

WebRTC's adaptive jitter buffer held about 124 ms on this link. I tried `WebRTC-ForcePlayoutDelay` bounds with the rig pair: tuftlord's display captured, HEVC 4:4:4, 30 Mbit/s, viewer HUD off, this Mac on Wi-Fi, frame clock video, 45 s each.

| playout bounds                     | updates/s | gap p50 / p95 ms | image age p50 / p95 ms |
| ---------------------------------- | --------: | ---------------: | ---------------------: |
| adaptive (before)                  |      47.8 |          18 / 36 |              227 / 256 |
| 0 / 0 (render as soon as possible) |      27.0 |         20 / 107 |               99 / 209 |
| 0 / 0 + render on arrival          |      33.0 |         18 / 103 |              109 / 210 |
| 1 / 15 (paced)                     |      37.9 |          18 / 71 |              118 / 159 |
| 1 / 40                             |      41.1 |          18 / 53 |              135 / 163 |
| 1 / 80                             |      43.5 |          18 / 37 |              174 / 193 |
| **15 / 80 (chosen)**               |      45.3 |          18 / 37 |              180 / 199 |
| 30 / 80                            |      46.5 |          18 / 36 |              180 / 195 |

Zero delay halves the image age, but over Wi-Fi frames arrive in bursts, so many are never shown and the gaps grow. **15 / 80** keeps almost all the smoothness and cuts about 50–60 ms. The 15 ms floor stays low for wired links, where the adaptive buffer would sit lower anyway.

**App path, same link** (the app's viewer against tuftlord's app host, both at the #125 build):

|                   | updates/s | gap p50 / p95 ms | image age p50 / p95 ms |
| ----------------- | --------: | ---------------: | ---------------------: |
| #125 only         |      50.2 |          17 / 35 |              200 / 227 |
| + playout 15 / 80 |      48.1 |          17 / 36 |          **175 / 182** |

Against the 851-2371 targets (Apple HP, wired, 4K):

- updates/s: 48.1 against ≥ 45 ✓
- gap p95: 36 ms against ≤ 36 ms ✓
- image age: 175 / 182 ms against 158 / 228 ms. p95 is better than Apple's; p50 is still 17 ms behind, measured on Wi-Fi.

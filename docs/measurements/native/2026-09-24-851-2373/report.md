# 851-2373 — 4K60 without encoder drops

`screen-sharing-rig probe --loopback --headless`, synthetic motion, 30 Mbit/s,
10 s (8 s for the sweep), this Mac (M4 Max).

## Cause

VideoToolbox's low-latency rate control can't keep up past 1440p. At 4K
each HEVC frame takes 36 ms p50 / 43 ms p95 to encode, so with two frames
in flight the encoder admits ~43 fps and drops the rest (109–137 drops in
10 s). More frames in flight only doubles the latency (86 ms p95, same
throughput). Standard rate control encodes the same 4K frames in 18 ms and
drops nothing.

| encode p50 / p95 |          1080p |          1440p |                        4K |
| ---------------- | -------------: | -------------: | ------------------------: |
| low-latency      |   8.1 / 9.1 ms | 12.6 / 14.1 ms | 35.7 / 42.6 ms, 109 drops |
| standard         | 13.0 / 15.8 ms | 19.8 / 24.5 ms |    17.8 / 19.9 ms, 1 drop |

Standard's largest gap between decoded frames was also smaller (42–48 ms
vs 66–301 ms).

## Fix

`ScreenSharingEncoder` uses low-latency rate control up to 2560×1440
pixels, where it's fastest, and standard above (`usesLowLatencyRateControl`).

## After (defaults)

| codec | size  | rate control | captured | encoded | drops | decoded | encode p95 |
| ----- | ----- | ------------ | -------: | ------: | ----: | ------: | ---------: |
| HEVC  | 1080p | low latency  |      596 |     586 |     2 |     586 |     8.9 ms |
| HEVC  | 4K    | standard     |      602 |     595 |     1 |     591 |    20.0 ms |
| H.264 | 1080p | low latency  |      598 |     587 |     1 |     586 |     8.4 ms |
| H.264 | 4K    | standard     |      603 |     595 |     1 |     591 |    22.6 ms |

4K60 in loopback: ~59 fps (target ≥ 58). Two-Mac confirmation waits for
tuftlord and for the host to send 4K (today it scales to ≤ 1080p; the
virtual display, 851-2376, lifts that).

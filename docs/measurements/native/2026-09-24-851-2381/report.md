# 851-2381: HEVC Main 4:4:4 by default (loopback)

Date: 2026-09-24. Mac: this development Mac (Apple silicon), loopback probe, headless, desktop pattern, 60 fps, 20 Mbit/s target, 10 s runs (600 frames).

The low-latency VideoToolbox rate control can't encode 4:4:4 (it may reduce chroma), so Main 4:4:4 uses standard rate control. With the encoder's speed preference it costs about 3 ms more encode time at 1080p than HEVC Main with low-latency rate control. At 4K the product already used standard rate control (851-2373), and 4:4:4 costs nothing extra.

| Codec, size           | Rate control                       | Encoded / 600 | Drops | Encode p95  |
| --------------------- | ---------------------------------- | ------------- | ----- | ----------- |
| HEVC Main, 1080p      | low latency (product before)       | 582           | 1     | 9.0 ms      |
| HEVC 4:4:4, 1080p     | standard                           | 596           | 1     | 15.6 ms     |
| HEVC 4:4:4, 1080p     | standard + no lookahead            | 598           | 0     | 18.3 ms     |
| **HEVC 4:4:4, 1080p** | **standard + speed (product now)** | **598**       | **0** | **12.4 ms** |
| HEVC 4:4:4, 1440p     | standard + speed                   | 596           | 1     | 18.0 ms     |
| HEVC Main, 4K         | standard + speed                   | 596           | 1     | 20.3 ms     |
| HEVC 4:4:4, 4K        | standard + speed                   | 594           | 1     | 19.7 ms     |

Decode p95 for 4:4:4 was 2.5 ms at 1080p and 5.3 ms at 4K.

## Negotiation

Real RTCPeerConnection offer/answer (ScreenSharingCodecFallbackTests): libwebrtc tells the two H.265 profiles apart by profile-id.

- New app with new app: Main 4:4:4.
- An app from before this change on either side: HEVC Main.
- An app from before 851-2372: H.264.

The host reads the answer's codec and captures in its format: BGRA for 4:4:4, NV12 otherwise.

## Not yet measured

Text sharpness against Apple High Performance on the Phase 0 measure, and stalls on two Macs. Both wait for tuftlord.

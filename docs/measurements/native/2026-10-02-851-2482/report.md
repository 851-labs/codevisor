# 851-2482: capture size, frames in flight and bitrate on an M1 Pro host

**Setup**

- Host tuftlord (MacBook Pro M1 Pro, 3024×1964). Viewer: this Mac (M4 Max), Tailscale direct over the LAN (about 270/430 Mbit/s).
- Rig to rig, HEVC 4:4:4, SDR, with the product's WebRTC trials (playout 15–80 ms, pacing ×10) unless noted.
- Frame clock in `frame-clock/` (two rounds, 40 s per run); host telemetry in `host-telemetry/`.
- A standalone VideoToolbox bench: `encoder-bench.swift`, with results in `encoder-bench-tuftlord.txt`.

## Frame clock (round 3, product trials, rig window in front)

| Setting                                  | Updates/s, video / scroll | Image age p50 / p95  | Gap p95   |
| ---------------------------------------- | ------------------------- | -------------------- | --------- |
| Today: 1662×1080, 2 in flight, 30 Mbit/s | 38–45 / 41–44             | 164–171 / 183–224 ms | 34–36 ms  |
| 1662×1080, 3 in flight, 45 Mbit/s        | 39–44 / 40–46             | 164–171 / 184–242 ms | 35–36 ms  |
| 2216×1440, 3 in flight, 45 Mbit/s        | 36–37 / 39–42             | 185–194 / 206–296 ms | 38–51 ms  |
| 3024×1964, 4 in flight, 45–60 Mbit/s     | 16–27 / 31–44             | 135–506 / 260–636 ms | 35–198 ms |
| Apple High Performance, 4K (851-2371)    | 48 / 46                   | 150–158 / 161–228 ms | 36 ms     |

## Where frames go at native size

- **Encoder admission:** with 2 frames in flight, the encoder's admission limit dropped 44% of frames. With 3–4 it dropped about 0–6%.
- **The hardware keeps up:** the synthetic encoder bench did native 4:4:4 at 60 fps with 4 in flight, at about 42 ms p50 encode under worst-case noise.
- **WebRTC drops the rest before the encoder:** at native it lowers the encoder's target below its own bandwidth estimate (11–33 Mbit/s target against a 24–36 Mbit/s estimate) and drops frames to match, because VideoToolbox overshoots on large frames.
- **Disabling the frame dropper or bitrate adjuster didn't help reliably.**
- **No effect:** 4:4:4 YCbCr input instead of BGRA, the speed-priority flag, and 4:2:0 instead of 4:4:4.

## Invalid runs, kept for the record

- **Round 1:** ran in HDR by accident (the rig's debug viewer asked for HDR automatically). The rig now asks only with `"hdr": true`.
- **Round 2:** the rig window was covered while the viewer Mac was in use, so its drawing was throttled.
- **Kernel panic:** the encoder bench's 8-bit 4:4:4 YCbCr input case at 1662×1080 panicked tuftlord (`dart-ave0`). Don't rerun it.

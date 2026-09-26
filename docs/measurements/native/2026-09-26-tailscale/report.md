# Native path vs Apple High Performance over Tailscale

Date: 2026-09-26.

- **Host:** tuftlord (M1 Pro) on its home network.
- **Viewer:** this Mac, on another network.
- **Path:** Tailscale, direct (not relayed): ~360 Mbit/s, 3–7 ms round trip.
- **Measure:** the frame clock (`bun run vnc:frame-clock`) with `--page-host` / `--host-key-alias` ([#164](https://github.com/851-labs/codevisor/pull/164)). Video mode, 45 s per run, viewer windows about 1180×760 pt.
- **Page:** `&strip=left`, because a persistent macOS notification banner on the host covered the right end of a full-width strip. It turned the first 1078 runs into 45% "torn", which is a measurement artefact; those runs are discarded.

## Results

| Viewer                                             | Runs | Updates/s |   Gap p95 | Image age p50 / p95  |
| -------------------------------------------------- | ---: | --------: | --------: | -------------------- |
| Codevisor native, alpha 1074                       |    2 |     28–45 |  35–92 ms | 255–517 / 501–539 ms |
| Codevisor native, alpha 1078                       |    3 |     43–45 |     36 ms | 187–211 / 201–226 ms |
| Apple High Performance                             |    2 |     17–25 | 35–195 ms | 103 / 217–240 ms     |
| Apple High Performance (earlier, full-width strip) |    1 |        15 |    229 ms | 124 / 246 ms         |

Every run has one ~4 s "longest gap": the page reload that starts the run landing inside it, not the stream.

## What changed between 1074 and 1078

[#166](https://github.com/851-labs/codevisor/pull/166).

- **Diagnosis:** on 1074 the host encoded 35 keyframes in ~90 s, only 3 of them requested: one every 2 s, ~1.1 MB each at 4:4:4 1760×1416. WebRTC's pacer let each one leave at 2.5× the target bitrate, holding every frame behind it.
- **Change:** keyframes every 60 s instead of 2 s, and the pacer at 10×. These are the two remedies the LAN rig study measured on 2026-09-15 (`docs/plans/screen-sharing-rig.md`, rows H/I/C/J).
- **Result on 1078:** 7 keyframes in ~4 minutes (4 requested). The viewer decoded 12,997 of 13,021 frames.

## Reading

- **Over Tailscale, Codevisor now shows about twice Apple's update rate with a similar worst-case delay (p95).** Apple throttles to 15–25 updates/s on this path.
- **Apple's median delay is still ~90 ms lower (103 against ~190 ms).** That is the next gap. Candidates:
  - the 4:4:4 standard rate controller's encoder latency (~20 ms on the LAN study);
  - the 15–80 ms playout bounds;
  - presentation.

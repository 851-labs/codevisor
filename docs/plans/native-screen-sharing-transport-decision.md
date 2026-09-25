# Native screen sharing: transport decision (851-2378)

Status: decided 2026-09-25. **Keep tuned WebRTC.** Don't build our own UDP transport now.

## The question

With TURN and internet paths out of scope (LAN and Tailscale only, 851-2370), WebRTC's NAT traversal isn't needed. Would our own UDP media transport, like Apple High Performance's UDP 5900–5902, get closer to Apple than tuned WebRTC?

## Data (2026-09-25)

After 851-2374, tuned WebRTC on the app path, over Wi-Fi, against Apple HP's wired 4K baseline (851-2371):

|                               | updates/s | gap p95 | image age p50 / p95 |
| ----------------------------- | --------: | ------: | ------------------: |
| Codevisor native (#125, #126) |      48.1 |   36 ms |        175 / 182 ms |
| Apple HP                      |      48.3 |   36 ms |        158 / 228 ms |

Where a frame's time goes on the rig pair (display source, same Wi-Fi link):

| stage                  |                                                    time | own transport would change it?          |
| ---------------------- | ------------------------------------------------------: | --------------------------------------- |
| host capture → encode  |          ~10–12 ms encode p95 (speed-prioritised 4:4:4) | no                                      |
| network round trip     | 6 ms (ICE pair ~67 ms under load, before pacing tuning) | no: same link                           |
| receive jitter buffer  |                   15–80 ms bound (was ~124 ms adaptive) | **yes**: the only WebRTC-specific stage |
| decode                 |                                              ~2 ms mean | no                                      |
| receive → presentation |            p95 28–41 ms (drawable, compositor, display) | no                                      |

Other WebRTC mechanisms are cheap on these links:

- No NACKs, PLIs or retransmissions in a 30 s sample.
- The bandwidth estimator lets the host send ~22 Mbit/s at 4:4:4.

## What our own UDP transport would buy, and cost

- **Buys:** at most the jitter-buffer floor, 15 ms plus some pacing. Even then a receiver needs _some_ buffer to absorb Wi-Fi bursts. The measurements showed zero buffering drops frames on Wi-Fi (27 updates/s).
- **Costs:** congestion control, loss recovery (FEC and retransmission), encryption (DTLS-SRTP today), packetization, and keyframe and recovery signalling. All exist, are tested and are tuned in WebRTC; we'd have to rebuild them before matching today's behaviour. We'd also lose the TURN path if the internet scope ever returns.

## Decision

1. **Tuned WebRTC (a)** is the transport. It meets the frame-rate and gap targets and beats Apple's p95 image age. The remaining p50 gap (17 ms) is within the jitter-buffer floor and Wi-Fi noise.
2. **The UDP prototype (b) is not built.** Its best case is bounded by the one WebRTC-specific stage measured above, and that stage is now bounded by 851-2374.
3. **Revisit** if a wired two-Mac frame-clock run shows WebRTC-attributable delay (jitter buffer + pacing) above ~30 ms at p50, or if 4K60 at 4:4:4 needs more than the estimator allows.

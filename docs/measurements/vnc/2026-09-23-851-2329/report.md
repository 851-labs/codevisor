# 851-2329: why Contabo gets ~1 update per round trip — notes

`validate.md` is the gate's output: PASS (tests 321 + 92, interop 10/10,
bench A/B with no verdicts, tophat 24/24). Contabo tophat: 13/13.

## Finding: the route, not TigerVNC

The ticket assumed TigerVNC's congestion window was holding the drag back.
Measured end to end, the route from Contabo to this Mac is the limit:

| path                                                        | throughput      |
| ----------------------------------------------------------- | --------------- |
| this Mac ← Cloudflare                                       | 330 Mbit/s      |
| Contabo ← Cloudflare / → Cloudflare                         | 155 / 20 Mbit/s |
| this Mac ← Contabo, SSH over public IP                      | 1.5 Mbit/s      |
| this Mac ← Contabo, raw TCP over Tailscale (direct, 161 ms) | 0.5 Mbit/s      |

VNC's drag at 0.5–2.5 Mbit/s already fills that. Xvnc's encoder stats show
where the bytes go: the wallpaper exposed under a moving window is re-sent as
lossless full colour (762 of 888 KiB in one sample). The route itself is
outside this repo (no network changes were made).

## What changed

- `VNCQualityPolicy`:
  - a lower tier: JPEG quality 4 below 2 Mbit/s, back to 8 above 3 Mbit/s.
    On Contabo, quality 4 cut bytes per update from ~22 KB to ~8.5 KB and
    raised the median drag rate from 2.9 to 7.5 updates/s (3 runs each,
    `QUALITY=4|8 scripts/vnc-desktop-sample.sh`);
  - updates of 8 KB or more pool into 64 KB samples. Before, only single
    updates of 64 KB or more counted, and a slow link's drag updates are
    6–24 KB, so after the first frame the policy never decided.
- Connection Details shows the estimate behind the quality ("JPEG 8 ·
  ≈15.0 Mbit/s").
- `vnc:tophat`:
  - its picture check fails only when the right or bottom half is all black
    (a desktop that hasn't repainted after growing); a black terminal no
    longer trips it;
  - the Contabo flow reports the route after 20 s of streaming.

## Not fixed: the bandwidth estimate

On Contabo during a drag, the estimate read ≈15 Mbit/s while the pane received
0.94 Mbit/s. The policy therefore picks JPEG 8, never 4. Each update is timed
from its first byte to its last, but on a saturated link most of an update is
already buffered locally (kernel, WebSocket) when reading starts. The timing
shows local read speed, not the link. That needs a different estimator (a
follow-up), for example throughput while the stream is backlogged.

## Metric target

"Contabo drag ≥ 20 updates/s" is not reachable on a 0.5–1.5 Mbit/s route with
this content. The best JPEG 4 run reached 25 updates/s, the median 7.5.

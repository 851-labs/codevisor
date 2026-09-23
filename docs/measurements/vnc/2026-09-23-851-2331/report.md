# 851-2331: estimate the link, not the local buffer — notes

`validate.md` is the gate's output: PASS (tests 325 + 92, interop 10/10,
bench A/B with no verdicts, tophat 24/24). Contabo tophat during a drag: 13/13.

## The problem

`VNCQualityPolicy` timed each update from its first byte to its last. On a
slow link most of an update is already buffered locally when the client reads
it. Over WebSocket, codevisor-server pipes Xvnc's socket into the WebSocket,
so each Node read (≤ 64 KB) becomes a message that arrives whole. The timing
was local reading: on Contabo it estimated ≈15 Mbit/s on a route that delivers
~1–3.

## What changed

- `RFBInputStream` link timing, as TigerVNC's viewer does it: while an update
  is read (after its header, whose wait includes idle time), only reads that
  **waited for the network** (≥ 1 ms) count, with their wait. Buffered data
  adds neither bytes nor time, so it can't inflate the estimate. The clock is
  injectable; tests script the waits (no real time).
- `RFBUpdate.linkBytes` / `linkDuration`. The session feeds these to the
  quality policy instead of `byteCount` / `transferDuration`.
- The policy weighs a sample by its size (one per 64 KB). Over WebSocket,
  samples come from updates that span several messages, typically the first
  full frame, so one large frame can settle the quality. The per-update
  minimum drops to 4 KB.
- `vnc-bench` reports `link est. Mbit/s` (informational).

## Evidence

`vnc-bench` against the shaped links:

| scene  | profile            | link Mbit/s | received Mbit/s | link est. Mbit/s |
| ------ | ------------------ | ----------: | --------------: | ---------------: |
| photo  | lan (unlimited)    |           – |           434.3 |            521.4 |
| photo  | wan150 (50 Mbit/s) |          50 |            50.0 |             48.4 |
| photo  | constrained (10)   |          10 |           10.00 |             10.0 |
| scroll | any                |             |                 |    – (no sample) |

Scroll's 40 KB updates arrive as one delivery, so there is no sample. That is
correct: no sample is better than a falsely low one.

Contabo, product path (WebSocket over Tailscale), during a window drag:

- Estimate ≈3 Mbit/s (was ≈15). A trace of the first full frame: 94 KB arrived
  while waiting, in 0.288 s, which is 2.6 Mbit/s: the route's real burst rate.
  The average received (~0.84 Mbit/s) is lower because it includes the gaps
  between updates.
- Drag updates (2–16 KB) each arrive as one message and add no samples.
- The policy picks JPEG 8 (the estimate is above the 2 Mbit/s tier). The rig
  received 688 updates in 45 s, ~15 updates/s, during the drag.

## Acceptance criteria

- The estimator measures the link, not the local buffer: bench within 3% on
  both shaped links; Contabo within the measured burst rate.
- L1 tests: waited reads count with their wait; buffered data and sub-ms reads
  don't; nothing counts outside a timed span; a single large frame decides.
- "The policy picks JPEG 4 on Contabo" doesn't hold. The route bursts at
  ~2.6–3 Mbit/s, above the 2 Mbit/s tier, so JPEG 8 is the honest choice for
  the measured link.

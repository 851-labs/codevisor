# 851-2320: no O(n) buffer shifts in the read path — notes

`validate.md` is the gate's output: PASS (tests 315 + 92, interop 8/8, bench
A/B with no verdicts, tophat 24/24).

## What changed

- `RFBWebSocketTransport` (the path to VNC machines through their Codevisor
  server, e.g. Contabo) handed out bytes with `removeFirst`, shifting the rest
  of the buffered message on every read: a 1 MiB message read in 64 KiB pieces
  moved about 8 MiB. It now moves an offset and drops the consumed prefix once
  it is at least half the buffer, so each byte moves at most once on average.
- `RFBInputStream` already compacted that way; both now count the bytes they
  move, and operation-count tests bound them (≤ the payload for a 1 MiB read in
  64 KiB pieces, bytes intact).

## Metric target

"Large-update scene: read-path CPU down; no regression elsewhere." `vnc-bench`
connects over TCP (`RFBInputStream`, unchanged in behaviour), so it can't show
the WebSocket change; the bound is proven by the operation-count test instead
(~8 MiB moved → ≤ 1 MiB for that read). No regression elsewhere: the A/B has
no verdicts.

## Gate change

The first run flagged scroll/lan CPU per update 0.54 → 1.31 ms. The same
unchanged origin/main build read 0.54, 1.22, 1.45 and 1.7 ms across runs, with
and without being confined to efficiency cores (`taskpolicy -c utility`:
~1.5). Whole-process CPU time (timers, shaping and pacing included) drifts more
than any change moves it, so it is now reported but never a verdict; the gate
decides on exact counts, rates and latencies.

# 851-2324: network-shaping transport — validation

Machine: Apple M4 Max, macOS 27.2, AC power. Base: `afd153ca`.

`bun run vnc:validate` does not exist yet (851-2328); the available layers
were run directly.

| Layer          | Result                                                                                                       |
| -------------- | ------------------------------------------------------------------------------------------------------------ |
| L1/L2          | `RFBShapedTransportTests` (9) and `RFBReferenceServerTests` (8): 17 tests pass, 10 consecutive runs (≈0.2 s) |
| L1/L2 (full)   | Full Swift suite via the pre-commit hook                                                                     |
| L3 (real Xvnc) | Not available until 851-2325; no client code changed                                                         |
| Benchmark      | Not available until 851-2310; this issue provides its network profiles                                       |
| L4 (rig)       | Not applicable: no user-visible change                                                                       |

## Acceptance criteria

- **Seeded RTT, bandwidth and jitter:** `RFBLinkSchedule` computes each
  delivery as serialization at the link's bandwidth (back-to-back sends
  queue), plus half the round trip, plus seeded jitter clamped so bytes never
  reorder. Tested exactly: 150 ms RTT delivers at 75 ms; 12 500 bytes at
  10 Mbit/s take 10 ms and a second send waits for the first; 200 jittered
  deliveries replay identically for a seed, differ across seeds and stay in
  order.
- **Named profiles:** `RFBNetworkProfile.lan` (1 ms), `wan40` (40 ms,
  100 Mbit/s, ±2 ms), `wan150` (150 ms, 50 Mbit/s, ±5 ms), `constrained`
  (150 ms, 10 Mbit/s, ±5 ms); `named(_:)` for command-line use.
- **Injected clock:** `RFBShapedTransport<C: Clock>` applies the schedule to
  both directions on the given clock. Tests use `TestClock`: a read is still
  in flight 1 ms before its one-way delay and arrives at it; writes reach the
  peer after the one-way delay; the peer's close arrives after its data;
  `close` fails pending reads. No sleeps or real clocks in those tests.
- **Wiring:** a real `RFBClient` through a shaped link (`lan`, real time, no
  timing asserted) converges on the reference server's typing scene.

## Metric target

None (scaffolding).

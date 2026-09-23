# 851-2309: VNC session statistics in Connection Details — validation

Machine: Apple M4 Max, macOS 27.2, AC power. Base: `d727256a`.

`bun run vnc:validate` does not exist yet (851-2328); the available layers
were run directly.

| Layer          | Result                                                                                                                                                                                                                                                                                                    |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| L1/L2          | `RFBUpdateMeasurementTests`, `VNCScreenSharingSessionTests`, `RFBClientLoopbackTests`, `RFBServerMessageTests`, `RFBInputStreamTests`, reference-server and shaping suites: 63 pass; CoreMac `ScreenSharingDiagnosticsTests`, `RFBWebSocketTransportTests`, `VNCScreenSharingViewerBackendTests`: 11 pass |
| L1/L2 (full)   | Full Swift suite via the pre-commit hook; `bun run build:macos` succeeds                                                                                                                                                                                                                                  |
| L3 (real Xvnc) | Not available until 851-2325                                                                                                                                                                                                                                                                              |
| Benchmark      | Not available until 851-2310; this issue provides its per-update measurements                                                                                                                                                                                                                             |
| L4 (rig)       | Contabo VPS, idle Xfce desktop: Connection Details shows Route "VNC · WebSocket", Video 1227 × 754, Presented 0.0 fps, Receiving 0.00 Mbps, Updates 0.0 /s, Update latency p95 927 ms                                                                                                                     |

## Acceptance criteria

- **Session statistics:** each `RFBUpdate` carries its wire size (`byteCount`,
  from `RFBInputStream.consumed`) and its latency from the request it answers
  (`latency`, on an injectable clock). `VNCScreenSharingSession` feeds them
  into its metrics (`vncBytesReceived`, `vncUpdateLatency`) and reports the
  transport (`statistics()` → `vnc.transport`: TCP or WebSocket).
- **Connection Details:** `ScreenSharingViewerDiagnostics` derives updates/s,
  presented fps, receive Mbps, bytes per update and update-latency p95 for VNC
  sessions, and route "VNC · <transport>"; the product popover and the rig's
  mirror show them. Round trip stays empty for VNC until Fence (851-2312).
- **Deterministic:** the latency test scripts the client's clock (request at
  0 ms, update at 42 ms → 42 ms); the diagnostics test feeds snapshots at
  explicit times; the wire size of the 64 × 48 raw first update is asserted
  exactly (12 304 bytes).

## Notes

- Update latency includes the server's wait for a change, so on an idle
  desktop it reflects the first full frame and idle waits; under activity
  (and in `vnc-bench` scenes) it is request → applied.

## Metric target

No measurable change in `vnc-bench` update rate: the benchmark doesn't exist
yet; the added work per update is two counter increments and one sample.

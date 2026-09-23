# 851-2326: wire recorder for real-server fixtures — notes

`validate.md` is the gate's output: PASS (tests 292 + 92, interop 7/7, bench
A/B with no verdicts, tophat 24/24).

## What it is

- `RFBRecordingTransport` wraps a live transport and records what the client
  reads once `start()` is called — after authentication, so nothing
  credential-derived is stored.
- `RFBRecording` (JSON, `Fixtures/README.md`): source, framebuffer size, the
  bytes (base64 chunks) and the `expected` outcome — updates, SHA-256 of the
  final framebuffer's colour bytes, and every pseudo-rectangle and event in
  order (fence round trips excluded: timing, not content). `replay()` feeds
  the bytes to a fresh client with no server.
- `screen-sharing-rig vnc-record` captures a real server (against
  `vnc:interop --keep`), optionally moving the pointer first, and stores the
  replay outcome as the expectation.

## First fixture

`tigervnc-1.15-opening.json` (4.7 KB, 7 updates): TigerVNC's opening for a
client with every extension — continuous updates confirmed, clipboard caps,
the hidden cursor then `left_ptr` (10 × 16, hotspot 1,1) after a pointer move,
the 1024 × 768 layout, and xclock ticks as pushed updates. It now runs as an
L1 test in 0.1 s, no container needed.

## Evidence

- Every fixture replays to its recorded outcome; 5 consecutive runs identical.
- Recording the reference server's scroll scene and replaying it reproduces
  the live client's final framebuffer exactly; the fixture format round-trips
  through JSON.

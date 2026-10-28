# RFB recordings

Real servers' bytes, replayed by `RFBRecordingTests` with no server. Each file
is an `RFBRecording` (JSON): `source`, the framebuffer size after the
handshake, the bytes the client read (base64 chunks) and the `expected`
outcome of replaying them (updates, SHA-256 of the final framebuffer's colour
bytes, and the pseudo-rectangles and events in order). The bytes were recorded
after authentication, so no credentials are stored. The recorder has been
removed; `git log -S RFBRecordingTransport` finds it if a new fixture is needed.

| Fixture | What it pins |
| --- | --- |
| `tigervnc-1.15-opening.json` | TigerVNC 1.15's opening for a client with every extension: continuous updates confirmed, clipboard caps, the hidden cursor then `left_ptr` after a pointer move, the 1024 × 768 layout, clock ticks as pushed updates |
| `tigervnc-1.15-tight-lossless.json` | Tight without a quality level on a desktop with a plasma window: fill, palette and zlib rectangles, pinned to the exact framebuffer |
| `tigervnc-1.15-tight-jpeg.json` | Tight at quality 8: JPEG rectangles for the plasma window. `framebuffer` is `lossy` (JPEG decoding may differ across OS versions); updates and events are pinned |

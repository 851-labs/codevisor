# 851-2311: draw the pointer locally — notes

`validate.md` is the gate's output: PASS (tests 260 + 92, interop 4/4, bench
no regression, tophat 24/24).

## What changed

- **Protocol:** the client advertises Cursor (-239) and PointerPos (-232).
  `RFBCursorShape` decodes the shape (pixels + bitmask → premultiplied BGRA,
  empty = hidden, edge hotspots clamped, 256 × 256 maximum); `RFBUpdate`
  carries the last shape and pointer position an update held.
- **Reference server:** sends a configured shape to clients that advertise
  it, `setCursor`, `movePointer`; `RFBCursorShape.referenceArrow`. Parity
  test covers both encodings.
- **Viewer:** `ScreenSharingViewingSession.onCursorChanged` (VNC sets it;
  WebRTC keeps the no-op default) → endpoint →
  `ScreenSharingViewerSurface.showRemoteCursor`. In
  `ScreenSharingVideoSurface`, while controlling the shape is the real
  `NSCursor`, scaled to the video's on-screen size (it was an invisible 1×1
  image, so the pointer only moved when the server's picture did); while
  viewing, an overlay draws it at the host's position.
- **Rig:** the Loopback server sends the reference arrow.

## Real-server behaviour (TigerVNC 1.15, L3)

Until this client moves the pointer, Xvnc draws the pointer into the
framebuffer itself and reports the cursor hidden (0 × 0), so a viewer sees
it where it is. After the client's first pointer event it sends the real
shape (`left_ptr`, 10 × 16, hotspot 1,1) and stops drawing it: exactly the
Control-mode case. The client handles both. Two interop-harness fixes came
out of it: the container sets a root pointer as a desktop would
(`xsetroot -cursor_name left_ptr`), and `vnc:interop` now waits for the
entrypoint's "ready" line, not only the RFB greeting (a race: the tests
could connect before the root colour was painted).

## Metric target

"Input-to-cursor latency < 1 frame under wan150": met by construction. While
controlling, the pointer is the local `NSCursor` with the server's shape, so
it moves with the Mac's own pointer and no network round trip is involved.
Evidence: `aShapeBecomesTheControlCursorAndHidingRestoresTheBlankOne` (the
control cursor is the shape, not the blank image) and the L3 test (Xvnc
sends the shape once the client moves the pointer). `vnc-bench`'s
input-to-update latency measures server echo, which is unchanged, as
expected.

## Manual

Moving the pointer while controlling needs keyboard/mouse focus, which the
scripted tophat never takes: check once by hand in the rig (Loopback server →
Control → the arrow follows the pointer instantly, even on Contabo).

# 851-2314: the remote desktop follows the window — notes

`validate.md` is the gate's output: PASS (tests 279 + 92, interop 6/6, bench
A/B against origin/main with no verdicts, tophat 24/24).

## What changed

- **Protocol:** the client advertises ExtendedDesktopSize (-308), parses its
  rectangles (reason, status, screen layout; the framebuffer resizes only on
  success) and sends SetDesktopSize with the server's screen id.
- **Session:** `requestDesktopSize(width:height:)` (a new
  `ScreenSharingViewingSession` method; WebRTC keeps a no-op) waits for the
  size to hold 400 ms (injectable sleeper), clamps to 320 × 240 … 8192 × 8192,
  sends only when the server supports resizing, hasn't refused, and the size
  differs; a size asked for before the server announced support is sent when
  it does. A refusal stops further requests: the viewer keeps scaling.
- **Viewer:** `ScreenSharingVideoSurface.onSizeChanged` reports its size in
  points; the endpoint forwards it to the session.
- **Reference server:** announces its layout, accepts or refuses
  SetDesktopSize (`desktopResize`), repaints after a resize; the scene server
  and the rig accept, and the rig's animated desktop repaints at the new size.
  The encoding helpers moved to `RFBLoopbackServer+Encoding.swift` (SwiftLint
  type length).

## Evidence

- **L2:** a burst of sizes sends one SetDesktopSize for the last, exactly at
  the debounce (TestClock: nothing at 399 ms, one at 400 ms); refusal stops
  further requests; a server without the extension is never asked; sizes are
  clamped.
- **L3 (TigerVNC 1.15):** Xvnc announces its layout and resizes through RandR
  to 800 × 600 on request (and back). With -308 advertised, its first update
  can carry only the layout, so the root-colour test now samples the first
  update with pixels; the interop suite is serialized because one test
  resizes the shared desktop.
- **L4:** after resizing the rig window to 960 × 640, Connection Details
  reports the remote desktop as 740 × 588 (the pane) instead of 1280 × 800,
  and the capture shows no letterbox.

**Metric target** — "matches the window within 1 s of the resize settling;
zero letterbox pixels when accepted": the debounce is 400 ms, the tophat saw
the new size on its first check after the resize, and the capture shows the
video filling the pane.

## Gate change: A/B against origin/main

The first gate run flagged scroll/lan CPU per update 0.57 → 1.14 ms. The same
benchmark on origin/main, run minutes later, read 1.45 ms: the stored
baseline had been recorded in a faster machine state. `vnc:validate` now runs
`vnc:bench --against-main` (build origin/main in `tmp/vnc-bench/main-worktree`,
benchmark it first, compare the change with it); the stored baseline stays the
historical record.

## Product note

Resizing follows the viewer in View mode too, so another viewer of the same
desktop (or an agent using it) sees the size change. That matches the issue
as written; if a viewer that is only watching shouldn't resize, gate
`requestDesktopSize` on Control mode.

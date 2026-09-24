# 851-2338: one controller at a time, arbitrated by codevisor-server — notes

`validate.md` is the gate's output: PASS (tests 330 + 102, interop 10/10,
bench A/B with no verdicts, tophat 24/24). `bun run build:macos` succeeds.
Server: `rfb-client-filter` 6, `vnc-control` 5 and `screen-sharing-vnc` 14
tests, 100% coverage kept. Swift: `VNCControlLeaseTests` 4,
`RFBWebSocketTransportTests` 5, and the session and backend suites.

## Decision

alexandru, 2026-09-23: last one wins.

## Design

- **The lease rides the existing WebSocket:** text frames next to the RFB
  bytes (binary frames). Viewer → server: `{"type":"request","name":…}`,
  `{"type":"release"}`. Server → viewer: `{"type":"granted"}`,
  `{"type":"revoked","by":…}`.
- **Server (`VNCControlArbiter`, one per desktop):** a request hands control
  over at once and tells the previous controller who took it.
- **Enforced on the server (`RFBClientStreamFilter`):** each viewer's RFB
  stream (3.8, None or VNC auth) is followed message by message.
  PointerEvent, KeyEvent and ClientCutText (including Extended Clipboard) pass
  only from the controller; SetDesktopSize only from the controller, or with
  nobody in control from the most recent viewer. Every other byte passes in
  order. Anything the filter can't follow switches to pass-through: never a
  corrupted stream.
- **Compatibility:** a viewer that never sends a lease message (an older app)
  isn't arbitrated, so its control keeps working. The capabilities reply
  advertises `controlLease: true`; the app uses the server's lease only when
  it's there, and grants locally otherwise (older servers, direct VNC).
- **Relay:** `spliceVNCSocket` now pumps both ways itself (filter in,
  high-water pause/resume out) instead of piping.
- **App:** `RFBWebSocketTransport` hands text frames to `onControlText`
  (they used to fail the connection). `VNCHostEmulator` asks the server for
  control, and turns `revoked` into the lease's own revoke ("Laptop took
  control."), releasing held buttons and keys. Releasing tells the server.

## Acceptance criteria

- Viewer A controls; B takes over; A is revoked and told who took it; A's
  input and SetDesktopSize no longer reach the desktop; B's do. Shown in the
  server relay test (two WebSockets through the real splice to an echoing VNC
  server).
- Watch-only panes can't resize unless they're the driver (the arbiter's
  `mayResize`, with Dynamic Resolution from 851-2340).
- Closing the controller's socket frees the lease (arbiter `leave`).

## Not yet verified on Contabo

Contabo runs codevisor-server 0.1.102, which predates this; the app falls
back to local control there (no `controlLease` in its capabilities). The
two-viewer hands-on check (rig and app on Contabo, take control in one and
then the other) waits for Contabo to run a server with this change.

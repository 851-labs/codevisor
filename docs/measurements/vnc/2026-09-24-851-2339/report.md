# 851-2339: codevisor-server sets a VNC desktop's scale — notes

`validate.md` is the gate's output: PASS (tests 325 + 102, interop 10/10,
bench A/B with no verdicts, tophat 24/24). Server tests
(`src/routes/screen-sharing-vnc*`): 16 passed, 100% coverage kept. Swift:
`ServerScreenSharingScaleTests` and the host and viewer suites pass.

## What changed

- **API:** a `setScale` operation with `scale` 1 or 2. A display may list
  `scales` and its provisioned `defaultWidth` and `defaultHeight`.
- **Config:** `screen-sharing.json` gains `desktop` ("xfce") and
  `defaultSize` ("1440x900"), which `scripts/vnc-desktop.sh` now writes.
- **Server:** `xfceScaler` does what the script's `SCALE` does (851-2330),
  but from the server:
  - finds the session's D-Bus in xfce4-panel's environment (never a second
    xfconfd);
  - sets the window scaling and matching borders (Default-xhdpi at 2×; back to
    Default only if it was the 2× theme);
  - restarts xfdesktop only when the scale changed.
    Commands go through an injectable runner, so tests need no Xfce.
- **Provider:** `capabilities` lists the scales and default size;
  `setScale` answers ok, error (unknown display, no scale, the session isn't
  running) or unsupported (no scaler).
- **Swift client:** the operation and fields. The Mac host and Computer Use
  live view answer `setScale` as unsupported.

## Not yet verified on Contabo

Contabo runs codevisor-server 0.1.102 (`/opt/codevisor`), which predates this
change and hasn't updated itself. The `setScale` round trip on the real
desktop waits for Contabo to run a server with this change. The scaler's
command sequence is the one proven by hand in 851-2330.

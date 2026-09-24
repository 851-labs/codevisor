# VNC viewer

Validation of every change: [vnc-validation.md](vnc-validation.md) (skill `vnc-change`).

Standard RFB/VNC servers as a second screen-sharing backend, added on top of the
composable architecture (`docs/plans/screen-sharing-composable-architecture.md`).
The pane, reducer, control lease, endpoint, surface, renderer and clipboard
transfer are reused unchanged; VNC plugs in at the `ScreenSharingViewerBackend`
and `ScreenSharingViewingSession` seams.

## Stages

1. **`ScreenSharingRFB`** (`packages/swift/ScreenSharingRFB`, depends on system zlib only).
   RFB 3.3/3.7/3.8 handshake, security None and VNC Authentication (DES via
   CommonCrypto), ClientInit/ServerInit, client messages (SetPixelFormat,
   SetEncodings, FramebufferUpdateRequest, KeyEvent, PointerEvent,
   ClientCutText), server messages (FramebufferUpdate, SetColourMapEntries,
   Bell, ServerCutText), encodings Raw, CopyRect, ZRLE and the DesktopSize
   pseudo-encoding, into a BGRA framebuffer. `RFBClient` runs the read loop
   over an `RFBTransport` (`RFBNetworkTransport` on Network.framework; a
   scripted transport in tests). Fixture-tested byte for byte; an in-process
   `RFBLoopbackServer` (test support) drives end-to-end tests over TCP.
2. **`VNCScreenSharingSession`** in `CodevisorCoreMac/ScreenSharing/VNC`:
   a `ScreenSharingViewingSession` copying the framebuffer into pooled
   `kCVPixelFormatType_32BGRA` buffers on every update; `capabilities`
   `[.control, .clipboard]` with a local, self-granting control channel so the
   existing lease reducer works, mapping `ScreenSharingInputEvent` to
   PointerEvent/KeyEvent (key codes → keysyms via `UCKeyTranslate`); a
   clipboard channel bridging ServerCutText/ClientCutText.
   `ScreenSharingViewerBackend.vnc(target:password:)` connects, reconnects up
   to three times after video, and reports `ended` with a readable message.
3. **Pane**: `ScreenSharingPanePreferences.vnc` (host, port, username) rides
   the existing opaque pane metadata; the password lives in the Keychain
   (`KeychainValueStore`, account `host:port`). The screen picker gains
   "Connect to a VNC server…"; the pane installs the VNC backend when a target
   is present. Tophat against macOS Screen Sharing with a VNC password.
4. **Later**: Apple Remote Desktop auth (type 30, DH + AES-128), Tight
   encoding, cursor pseudo-encoding, ExtendedDesktopSize, audio (none in RFB).

## Wire choices

- Client pixel format: 32 bpp, depth 24, little-endian, shifts R16 G8 B0 — the
  bytes in memory are B,G,R,X, which is `kCVPixelFormatType_32BGRA`, so the
  renderer's existing BGRA path draws it with no conversion. ZRLE CPIXELs are
  then 3 bytes (B,G,R).
- One outstanding incremental FramebufferUpdateRequest at a time, issued as
  soon as the previous update is applied. The first request is non-incremental.
- Errors are terminal: an unknown encoding or malformed message ends the
  session with a message; there is no resynchronisation in RFB.

## Status

Stages 1–3 have landed. What exists:

- `packages/swift/ScreenSharingRFB` (protocol, 36 fixture and loopback tests) and
  `ScreenSharingTesting` (`packages/swift/ScreenSharing/Sources/ScreenSharingTesting`, the in-process server used by tests and the rig).
- `CodevisorCoreMac/ScreenSharing/VNC`: `VNCScreenSharingSession`, `VNCHostEmulator`,
  `VNCKeyTranslator`, `VNCInputTranslator`, `VNCFramePublisher`,
  `ScreenSharingViewerBackend.vnc(target:password:)` and `dispatchingVNC(password:)`,
  `ScreenSharingVNCCredentials` (Keychain service `com.851labs.Codevisor.vnc-password`,
  account `host:port`).
- `ScreenSharingPanePreferences.vnc` and the pane's "VNC server" form; the target rides
  the pane's registry metadata, the password never leaves the Keychain.
- `screen-sharing-rig vnc-server`: a loopback VNC server with an animated desktop and an
  input log, for tophats without third-party software.

To tophat against macOS itself, enable Screen Sharing with a VNC password once:

```sh
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -configure -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw secret
```

Not yet: Apple Remote Desktop authentication (type 30), Tight encoding, cursor
pseudo-encodings, ExtendedDesktopSize, a display size in the picker before the first
connection.

## Interop test box

Locally, `bun run vnc:interop` runs the interop suites against a pinned TigerVNC
container (`apps/screen-sharing-rig/scripts/vnc-interop/`, needs OrbStack or Colima running) with a
known desktop; it is layer L3 of `vnc-validation.md`. The box below remains
the WAN and real-desktop check.

A Contabo Cloud VPS 4 (`164.68.121.169`, Ubuntu, monthly; credentials in
1Password as "Contabo VNC test box") runs TigerVNC as a real, standard VNC
server for interop testing. `apps/screen-sharing-rig/scripts/vnc-test-box.sh provision root@164.68.121.169`
installs it (idempotent, bound to localhost); `apps/screen-sharing-rig/scripts/vnc-test-box.sh tunnel
root@164.68.121.169` forwards `127.0.0.1:5901`, which the pane connects to.
Contabo's own KVM console (VNC Information in the panel) is a second, QEMU-based
server worth testing against.

### Interop results (TigerVNC 1.13 on the box, through the tunnel)

Verified from the app: RFB 3.8 + VNC Authentication, a 1440 × 900 ZRLE desktop
(23 rectangles in the first update, ~2 s over the tunnel), repaint on change,
reconnection after the socket dropped, and input under the local lease — keys,
modifiers (⌃C reached the shell as `^C`), Return; `ls` ran remotely. Two bugs
came out of it and are fixed: the viewer read the previous Keychain password
because the save and the connection ran concurrently, and the renderer never
reported a presentation for a sparsely presented layer (`presentedTime` is 0
for every drawable of a desktop that only repaints on change), so the pane
never left "Connecting…". The env-gated tests `RFBInteropTests`,
`VNCSessionInteropTests` (`VNC_TEST_HOST/PORT/PASSWORD`) and
`ScreenSharingSurfacePresentationTests` (`SCREEN_SHARING_WINDOW_TESTS=1`)
reproduce the setup.

Synthesized typing (Computer Use `typeText`, key code 0 with a Unicode payload)
is sent as text (851-2318): a key-code-0 press whose characters aren't what
that key gives on the local layout (and without Control or Command) becomes
`.text`, which reaches a VNC server as the characters' keysyms (Unicode keysyms
`0x1000000 + code point` beyond Latin-1). Every other key is still forwarded as
a physical key for the layout to interpret. QEMU Extended Key Events (−258,
layout-independent scancodes) were considered and deferred: they would hand
layout interpretation to the server.

⌘ is sent as Control (851-2317): ⌘C, ⌘V, ⌘T and ⌘Q do what Mac hands expect
in Linux apps. Both ⌘ keys send Control_R, clear of the left Control key;
Control stays Control and Super is not sent. In a terminal ⌘C is therefore
Control+C (interrupt): Linux terminals copy with Control+Shift+C (⌘⇧C).
Control–Option–Escape still leaves control.

Dynamic Resolution (851-2340, replacing 851-2315's Retina setting): a toolbar
toggle next to View/Control, remembered per machine (by machine id, so Codevisor
Cloud machines too), on by default, shown only for desktops that can resize.

- **On:** the remote desktop follows the pane. On a Retina display, with a
  desktop that can draw at 2× (its server lists scale 2, 851-2339), it gets a
  pixel per device pixel and the server sets the desktop's UI scale to match.
  On a slow link (under ~15 Mbit/s, back above ~25) it drops to 1× pixels.
  Without a scalable desktop it follows at 1× pixels.
- **Off:** the viewer doesn't touch the desktop. If this viewer had changed it,
  the provisioned size (or the size at connect) and 1× come back.
- **Connection Details** says which ("dynamic · 2×", "dynamic · 1× (slow
  link)", "fixed size").
- **Tooling:** `SCALE=2 scripts/vnc-desktop.sh` still sets 2× by hand.

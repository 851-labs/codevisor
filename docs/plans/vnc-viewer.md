# VNC viewer

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

# Screen sharing for VPS workspaces

Follows `docs/plans/vnc-viewer.md`. Screen sharing must feel the same on every
workspace machine: open the tab, the stream appears, switch displays from the
toolbar. VNC is how a Linux VPS gets there and is never shown to the user.

## Stages, each a commit on `main`

1. **Auto-connect and a display menu.** A new Screen Sharing tab connects at
   once: to the display the pane last used when it is still listed, else the
   first one. The toolbar gains a display menu that reconnects on choice. The
   picker view goes; failures show the message and Retry in place.
2. **The rig becomes an app.** A SwiftUI window with a sidebar of scenarios:
   Native session (today's two-Mac rig), Probe, Raw VNC (host/port/password
   against the same session and surface the product uses), Loopback server
   controls, and a metrics panel. The raw VNC form, the saved target and the
   Keychain password move there from the app; `ScreenSharingPanePreferences.vnc`,
   `ScreenSharingVNCCredentials` and `dispatchingVNC` leave the product.
3. **Server: a VNC provider.** `apps/server` reads
   `~/.codevisor/data/screen-sharing.json` (`{ "vnc": { "port": 5901, "name": … } }`,
   written by provisioning) and, when present, advertises `screen-sharing-v1`
   in `/v1/info` and answers `capabilities` with `provider: "vnc"` and one
   display. `GET /v1/screen-sharing/vnc/socket?displayId=…` (bearer auth like
   every other WebSocket route) splices the client's WebSocket to the display's
   loopback TCP port. The display runs TigerVNC `-localhost -SecurityTypes None`:
   only the authenticated relay reaches it, so no DES password exists anywhere.
4. **Client: provider switch.** `RFBWebSocketTransport` (URLSession) behind the
   existing `RFBTransport`. The native backend keeps signaling as it is; when
   `capabilities` says `provider: "vnc"` it opens the socket and runs a
   `VNCScreenSharingSession` instead of a WebRTC one. Through the cloud relay
   the socket rides the same loopback bridge every other request uses.
5. **The VPS as a workspace.** `codevisor-server` installed on the box with the
   public installer, paired to Codevisor Cloud (`codevisor auth login`), the
   desktop provisioned by `scripts/vnc-desktop.sh` (TigerVNC + Xfce as a
   systemd unit, the JSON above), and a dev deploy script that builds the Linux
   archive on the box from the working tree. Tophat: open the VPS workspace in
   the app, Screen Sharing, stream.

## Status

- Stage 1 landed (de6bb786) and verified in the dev app: a new tab connects
  to the Built-in display at once; the toolbar's Display menu lists the Mac's
  displays.
- Stage 2 landed (93656285, efc41831, 32b177b8, bf1c74c9): the rig window
  with Raw VNC and Loopback server scenarios; the pane no longer takes a VNC
  target, password or preference.
- Stage 3 landed (4f936eca): `apps/server/src/routes/screen-sharing-vnc.ts`
  with tests for the config file, `capabilities` and the socket splice.
- Stage 4 landed: `RFBWebSocketTransport`, `screenSharingVNCSocket` on the
  client, and the native backend's provider switch, tested against the
  loopback server.
- Later (2026-09-22): the rig's Raw VNC scenario was removed. The window lists
  machines viewed through the product's `ScreenSharingViewer` store; the
  loopback server appears there while it runs, over the product's `.vnc`
  backend (now public).
- Stage 5 done on the Contabo box (164.68.121.169): `codevisor-server` from
  the public installer, then `scripts/deploy-dev-server.sh` swapped in a
  runtime built from the working tree (the release lacks the provider);
  `scripts/vnc-desktop.sh` provisioned the desktop; the box is paired to the
  dev cloud through an SSH reverse tunnel (`ssh -R 49372:localhost:49372`)
  with `codevisor auth login --server http://127.0.0.1:49372`. Tophat: in the
  dev app, New chat on "Contabo VPS" (no project) → New Tab → Screen Sharing
  connects at once and streams the Xfce desktop; Xvnc sees one loopback
  client owned by codevisor-server. Pairing to production cloud waits for a
  release that carries the viewer.
- Day to day the box is reached over Tailscale instead of the cloud relay:
  `tailscale up --hostname contabo-vps` on the box, then the app adds it as a
  direct machine (`contabo-vps.tail6fc9a.ts.net:49361`, token from
  `codevisor token`); Screen Sharing then streams straight over WireGuard.
  The dev-cloud pairing stays for relay testing (needs the `ssh -R` tunnel).

## Not in scope

Managing the desktop from `codevisor setup`, multiple VNC displays, cursor
pseudo-encodings, audio.

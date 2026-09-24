# Screen Sharing rig

A two-Mac development loop for the native screen-sharing engine: one resident host process and one resident viewer process, signed with a stable identity, deployed with one command, showing live numbers. It is a consumer of `ScreenSharing` and `ScreenSharingWebRTC`, never shipped, and never installed on a user's machine. Design and status: [docs/plans/screen-sharing-rig.md](../../../docs/plans/screen-sharing-rig.md).

## Layout

| Target                     | Path                                                       | Purpose                                                                                                                                                                                                                                                                           |
| -------------------------- | ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ScreenSharingRigKit`      | `Sources/ScreenSharingRigKit`                              | Pure, tested pieces: `rig.json` parsing, signaling messages, a bounded HTTP/1.1 codec and listener, reconnect backoff, per-second telemetry samples, HUD formatting, JSONL writer.                                                                                                |
| `ScreenSharingRig`         | `Sources/ScreenSharingRig`                                 | The executable: `RigRunner` (state, telemetry tick), `RigRunner+Host`, `RigRunner+Viewer`, `RigHUDView`; `Shell/` is the window: a sidebar of Machines (`RigMachine.catalog`, plus the loopback server while it runs) over a Debug section (Loopback VNC server, Native session). |
| `ScreenSharingDiagnostics` | `apps/screen-sharing-rig/Sources/ScreenSharingDiagnostics` | Workload window, painter and synthetic source shared with the probe.                                                                                                                                                                                                              |

The bundle is `~/Applications/CodevisorRig/ScreenSharingRig.app` (`com.codevisor.ScreenSharingRig`), built and signed by `apps/screen-sharing-rig/scripts/screen-sharing-rig.ts` with the login keychain's Apple Development identity so Screen Recording, Accessibility and Local Network grants survive rebuilds.

## Commands

```sh
bun run screen-sharing:rig install --host tuftlord@tuftlords-macbook-pro --host-address 192.168.10.191 --capture workload:1920x1080@60
bun run screen-sharing:rig deploy          # edit → both Macs streaming again
bun run screen-sharing:rig status
bun run screen-sharing:rig sample --seconds 30
bun run screen-sharing:rig hud off
bun run screen-sharing:rig source app:com.apple.dt.Xcode   # switch the host's source on the live session
bun run screen-sharing:rig tune paced15-worker        # or a JSON object, or default; restarts both agents, ~3 s
bun run screen-sharing:rig control-check --clicks 5    # product control lease + injection on the host's virtual display
bun run screen-sharing:rig logs
bun run screen-sharing:rig stop --all
```

```sh
swift run --package-path apps/screen-sharing-rig screen-sharing-rig vnc-server --port 5901 --password secret --size 1280x800
```

The Loopback VNC server tab runs `RFBLoopbackServer`, the reference server VNC changes are validated against (`docs/plans/vnc-validation.md`): its Content menu plays the animated desktop or any deterministic `RFBLoopbackScene` (idle, typing, scroll, windowDrag, photo, resize), and "Echo pointer input" answers each pointer event with a marker whose colour encodes its sequence.

The probe, the single-process capture → encode → WebRTC → decode → render diagnostic, is command-line only: `--loopback` (default) or `--send`/`--receive` across two Macs with offer/answer files, ending in a JSON report.

```sh
bun apps/screen-sharing-rig/scripts/screen-sharing-probe.ts --help
swift run --package-path apps/screen-sharing-rig screen-sharing-rig probe --loopback --duration 10 --report /tmp/probe.json
```

The app has one window, whatever started it. Launched without arguments (`open -n ~/Applications/CodevisorRig/ScreenSharingRig.app`) it opens on the first machine; the resident viewer opens the same window on Native session, with the two-Mac session's video and HUD inside it, so the other scenarios are one click away from the running rig. Closing that window stops the viewer and exits cleanly, which the launch agent does not restart. A `sample` hides the sidebar for its duration.

Machines are listed in `RigMachine.catalog`: Codevisor servers (today: Contabo VPS over Tailscale) and VNC servers reached directly (today: tuftlord's macOS Screen Sharing, which needs "VNC viewers may control screen with password" on), plus "Loopback server" while the Loopback VNC server scenario is serving (its View button selects it). A direct VNC machine's password is never in source: the rig asks for it in place of the video, keeps it in the login Keychain (`com.codevisor.ScreenSharingRig.vnc-password`, per machine id) once the server accepts it, forgets it when the server rejects it, and View → Forget Password clears it. A server machine uses the product's `.native` backend; the loopback server, a plain VNC server with no Codevisor server in front, uses the product's `.vnc` backend, so it gets the same toolbar and control lease and its input log shows exactly what the product's control path sends. Selecting one runs the product's own Screen Sharing feature against it: the `ScreenSharingViewer` store over its `.native` backend, exactly as the app's pane builds it, so discovery, the control lease, clipboard and diagnostics are the product's. The window's native toolbar carries the product's View/Control switch, display menu, clipboard menu and Connection Details (`Shell/RigScreenSharingToolbar.swift` mirrors `apps/macos/.../ScreenSharingToolbar.swift`; keep them in step). The bearer token comes from `ssh <target> codevisor token` the first time (and again after a 401) and is kept in the login Keychain under `com.codevisor.ScreenSharingRig.machine-token`.

`vnc-server` is a standalone VNC server on 127.0.0.1 with an animated desktop (RFB 3.8, VNC Authentication or `--no-password`, ZRLE or `--encoding raw`). It prints the keys, button changes and clipboard text the viewer sends. It is the tophat target for the app's VNC viewer (`docs/plans/vnc-viewer.md`): open a Screen Sharing pane, enter `127.0.0.1`, port `5901` and the password under "VNC server".

`install` configures this Mac as the viewer and the SSH target as the host, writes both `rig.json` files and LaunchAgents (`com.codevisor.screen-sharing-rig`, GUI session, restarted only on abnormal exit), builds, pushes and starts both. `deploy` rebuilds and restarts both; run `install` again if the executable name or ports change. The host never builds: both Macs are Apple silicon and the bundle is `rsync`ed.

## How it works

- The viewer creates a receive-only offer and `POST`s it with a bearer token to the host's listener (port 48731); the host answers. Latest offer wins on the host. There is no ICE trickle; the peer gathers before offering, as the product does.
- The viewer reconnects with bounded backoff (1 → 10 s). On `disconnected` it asks the host whether its session still exists and skips the 5 s grace when the host has restarted. Kill or redeploy either side and media returns on its own.
- `capture: workload:WxH@fps` draws the probe's workload window in-process and captures it through current-process shareable content, which needs no Screen Recording grant. `display:ID` captures a real display and does. `virtual:WxH@fps` creates a HiDPI virtual display through the private `CGVirtualDisplay` API, puts the workload window on it and captures that display (Screen Recording again; rig only, removed with the session). `virtual-desktop:WxH@fps` is the same display left bare — its own desktop, named "Codevisor Rig Display" in Displays, so real applications can be moved onto it and streamed. `synthetic` needs nothing and no display.
- `app:BUNDLE` captures every on-screen window of one application and `window:ID` one window regardless of what covers it (both need Screen Recording). `source SPEC` switches the host between any of these on the live session: the peer and its negotiated size stay, so two sources compare under the same network conditions; a failed switch restores the previous source.
- Every second both processes append a `RigTelemetrySample` to `~/Library/Logs/CodevisorRig/<role>.jsonl` (rotated at 50 MB) and refresh the HUD. `H` toggles the viewer HUD; `POST /hud` toggles either. `POST /sample` on the viewer's loopback control port (48732) turns the HUD off, collects N seconds, fetches the host's snapshot and writes one report.
- The viewer calibrates its clock against the host (`GET /clock`, 25 bracketed exchanges, tightest interval, every 60 s) and shows live image age — capture timestamp to on-screen presentation — as p50/p95/max per second with the clock error. Not input-to-photon.
- `tuning` in `rig.json` (or `rig tune`) sets the WebRTC playout/jitter trials, the viewer renderer path and the host capture request at process start; both ends report the trial that was actually installed. It also carries the host encoder and transport knobs `keyframeIntervalSeconds` (1–60; product 2), `rateControl` (`lowLatency` | `standard`; Main444 forces `standard`), `pendingFrames` (1–8; product 2) and `transportCeiling` (bps; raises only the bandwidth estimator's cap — the encoder target stays capped at `bitrate`), `pacingFactor` (`WebRTC-Video-Pacing factor`, the pacer's multiple of the target bitrate, default 2.5, so a keyframe can leave faster than the average rate) and `staticCodecRate` (ignore the transport's rate updates; the encoder then keeps WebRTC's initial rate, not `bitrate`). A `tune` object may include `codec` (`h264` | `hevc` | `hevc444`) and `bitrate`, which move to the top of both configs.
- `control-check` drives the product's control protocol from the viewer over the real data channel (request → grant → clicks → release → revoke) against the product's own lease and CGEvent injector on the host, bound to the captured virtual display; the workload's Response counter proves delivery without touching a real desktop. Needs Accessibility on the host.
- Samples never contain SDP, addresses or credentials. The token is a trusted-LAN convenience, not an authorization system.

## Permissions

One-time per Mac and per identity: Local Network (prompted on first LAN connection), Screen Recording only for `display:` capture, Accessibility only when control is exercised. Closing the viewer window exits cleanly and the agent stays down until the next `deploy`.

# Screen Sharing rig

A two-Mac development loop for the native screen-sharing engine: one resident host process and one resident viewer process, signed with a stable identity, deployed with one command, showing live numbers. It is a consumer of `CodevisorScreenSharing`, never shipped, and never installed on a user's machine. Design and status: [docs/plans/screen-sharing-rig.md](../../../docs/plans/screen-sharing-rig.md).

## Layout

| Target | Path | Purpose |
| --- | --- | --- |
| `ScreenSharingRigKit` | `Sources/ScreenSharingRigKit` | Pure, tested pieces: `rig.json` parsing, signaling messages, a bounded HTTP/1.1 codec and listener, reconnect backoff, per-second telemetry samples, HUD formatting, JSONL writer. |
| `ScreenSharingRig` | `Sources/ScreenSharingRig` | The executable: `RigRunner` (state, telemetry tick), `RigRunner+Host`, `RigRunner+Viewer`, `RigHUDView`. |
| `ScreenSharingDiagnostics` | `../CodevisorScreenSharing/Diagnostics` | Workload window, painter and synthetic source shared with the probe. |

The bundle is `~/Applications/CodevisorRig/ScreenSharingRig.app` (`com.codevisor.ScreenSharingRig`), built and signed by `scripts/screen-sharing-rig.mjs` with the login keychain's Apple Development identity so Screen Recording, Accessibility and Local Network grants survive rebuilds.

## Commands

```sh
bun run screen-sharing:rig install --host tuftlord@tuftlords-macbook-pro --host-address 192.168.10.191 --capture workload:1920x1080@60
bun run screen-sharing:rig deploy          # edit → both Macs streaming again
bun run screen-sharing:rig status
bun run screen-sharing:rig sample --seconds 30
bun run screen-sharing:rig hud off
bun run screen-sharing:rig source app:com.apple.dt.Xcode   # switch the host's source on the live session
bun run screen-sharing:rig logs
bun run screen-sharing:rig stop --all
```

`install` configures this Mac as the viewer and the SSH target as the host, writes both `rig.json` files and LaunchAgents (`com.codevisor.screen-sharing-rig`, GUI session, restarted only on abnormal exit), builds, pushes and starts both. `deploy` rebuilds and restarts both; run `install` again if the executable name or ports change. The host never builds: both Macs are Apple silicon and the bundle is `rsync`ed.

## How it works

- The viewer creates a receive-only offer and `POST`s it with a bearer token to the host's listener (port 48731); the host answers. Latest offer wins on the host. There is no ICE trickle; the peer gathers before offering, as the product does.
- The viewer reconnects with bounded backoff (1 → 10 s). On `disconnected` it asks the host whether its session still exists and skips the 5 s grace when the host has restarted. Kill or redeploy either side and media returns on its own.
- `capture: workload:WxH@fps` draws the probe's workload window in-process and captures it through current-process shareable content, which needs no Screen Recording grant. `display:ID` captures a real display and does. `virtual:WxH@fps` creates a HiDPI virtual display through the private `CGVirtualDisplay` API, puts the workload window on it and captures that display (Screen Recording again; rig only, removed with the session). `virtual-desktop:WxH@fps` is the same display left bare — its own desktop, named "Codevisor Rig Display" in Displays, so real applications can be moved onto it and streamed. `synthetic` needs nothing and no display.
- `app:BUNDLE` captures every on-screen window of one application and `window:ID` one window regardless of what covers it (both need Screen Recording). `source SPEC` switches the host between any of these on the live session: the peer and its negotiated size stay, so two sources compare under the same network conditions; a failed switch restores the previous source.
- Every second both processes append a `RigTelemetrySample` to `~/Library/Logs/CodevisorRig/<role>.jsonl` (rotated at 50 MB) and refresh the HUD. `H` toggles the viewer HUD; `POST /hud` toggles either. `POST /sample` on the viewer's loopback control port (48732) turns the HUD off, collects N seconds, fetches the host's snapshot and writes one report.
- The viewer calibrates its clock against the host (`GET /clock`, 25 bracketed exchanges, tightest interval, every 60 s) and shows live image age — capture timestamp to on-screen presentation — as p50/p95/max per second with the clock error. Not input-to-photon.
- Samples never contain SDP, addresses or credentials. The token is a trusted-LAN convenience, not an authorization system.

## Permissions

One-time per Mac and per identity: Local Network (prompted on first LAN connection), Screen Recording only for `display:` capture, Accessibility only when control is exercised. Closing the viewer window exits cleanly and the agent stays down until the next `deploy`.

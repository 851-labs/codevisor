# Screen Sharing rig: a fast two-Mac iteration loop

Status: proposal, 2026-09-14. Nothing here changes product code, defaults, or the measurement archives. The rig is a development tool built on the existing `screen-sharing-probe` executable; it is never installed on user machines.

## Why

The engine (`packages/swift/CodevisorScreenSharing`) already has a standalone diagnostic app that needs neither the server nor the product app. The loop is slow anyway, for reasons that sit _around_ the probe rather than inside it:

| Friction today                                                                                                                                                                     | Evidence                                                                                              |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Screen Recording / Accessibility grants die on every rebuild because the probe is ad-hoc signed and TCC pins the code hash. 84 probe identities exist under `tmp/screen-sharing/`. | `scripts/screen-sharing-probe.mjs:109-110`, `packages/swift/CodevisorScreenSharing/README.md:113-128` |
| No deploy path to the second Mac. All two-Mac orchestration is untracked `tmp/*.py`; `launchctl asuser` fails over SSH; launching a binary over SSH attributes TCC to `sshd`.      | `docs/plans/native-screen-sharing-fable-progress.md:171-176`                                          |
| Signaling is a manual offer/answer file exchange with a copy-then-rename step and a 120 s timeout.                                                                                 | `README.md:152-172`                                                                                   |
| Metrics only exist as an end-of-run JSON report. The viewer window is a bare `NSWindow`; there is no live number to watch while a change streams.                                  | `Probe/ScreenSharingProbe.swift:271-306`                                                              |
| The host is a shared physical desktop; external Screen Sharing sessions and other operators changed the source mid-run and blocked three consecutive turns.                        | `native-screen-sharing-manager-current-direction.md:7-11,32`                                          |
| Every process-immutable knob (field trials, diagnostic profile) requires a fresh process, and every experiment has meant a fresh bundle identity and a fresh grant.                | `current-direction.md:37`, stage3u README:80-82                                                       |

## Target loop

Edit engine source → `bun run rig:deploy` → within about a minute, both Macs are streaming again with live numbers on screen. No System Settings visit, no SSH shell, no file copying. Product app builds happen only for integration checks.

## Design

One executable, one identity, one resident process per Mac.

### Identity and signing (removes the permission churn)

- Fixed bundle identifier `com.codevisor.ScreenSharingRig`, display name "Codevisor Screen Sharing Rig". No worktree hash in the identifier: the rig is a single installed tool, not a per-experiment artifact. Existing hashed probe identities stay untouched so archived measurements remain reproducible.
- Sign with the local **Apple Development** identity (present in the login keychain), never Developer ID: the rig must not be confusable with a shipping artifact, and no notarization is needed because `rsync` sets no quarantine attribute. `CODEVISOR_RIG_SIGN_IDENTITY` overrides; if no identity is found the script falls back to ad-hoc **with a loud warning**, since ad-hoc reintroduces the churn.
- The designated requirement then pins bundle identifier + team rather than the code hash; TCC grants survive rebuilds. Verify with `codesign -d -r- ScreenSharingRig.app` after the first and second build: the requirement string must be identical.
- Installed path is stable on both Macs: `~/Applications/CodevisorRig/ScreenSharingRig.app`.
- Grant Screen Recording and Accessibility once per Mac to that identity. Accessibility is needed on the viewer for the keyboard event tap and on the host for injection; the rig exercises both.

### Resident supervisor and push deploy (removes SSH launching)

- A user LaunchAgent `com.codevisor.screen-sharing-rig` (`RunAtLoad`, `KeepAlive`, `LimitLoadToSessionType: Aqua`) owns exactly one rig process in the GUI session. It is the only launcher; SSH is used for file transfer and `launchctl kickstart -k`, never to start the app, so TCC attribution is always the rig bundle.
- `bun run rig:deploy [--to <host>[,<host>]] [--config rig.json]`:
  1. `swift build -c release --product screen-sharing-probe` locally (incremental; both Macs are Apple silicon, so the remote Mac never builds).
  2. Assemble and sign the bundle (reuse the probe script's assembly; identity as above).
  3. Local: atomic swap into `~/Applications/CodevisorRig/`, then `launchctl kickstart -k gui/$UID/com.codevisor.screen-sharing-rig`.
  4. Remote: `rsync -a --delete` into `.staging/`, `ssh mv` atomic swap, remote `kickstart -k`. Uses key-based SSH to `tuftlord@tuftlords-macbook-pro` (verified: macOS 26.6.2, arm64). Signaling targets the host's Ethernet address `192.168.10.191` (`en7`), which shares the `192.168.10.x` subnet with the local Mac; tuftlord's Wi-Fi is on a different subnet and must not be the configured peer.
  5. `bun run rig:install` writes the LaunchAgent plist and the config once per Mac; `rig:status` prints both processes' build hashes and connection state; `rig:stop` bootouts the agent.
- Process-immutable knobs are not a problem here: every deploy is a fresh process by construction.

### Rig mode and auto-connect (removes the file dance)

- New probe mode `--rig host|viewer` next to the existing `loopback|send|receive`. It reuses `ProbeOptions` and the existing sender/receiver code paths; nothing in the measurement modes changes.
- Configuration lives in `rig.json` beside the app: role, peer address, port, shared token, codec, bitrate, fps, capture source (`display:<id>` | `workload:<WxH@fps>` | later `virtual:<WxH@fps>`), diagnostic profile, HUD on/off. The LaunchAgent passes only `--rig --config <path>`; `rig:deploy --config` can push a new file and restart without rebuilding.
- Signaling mirrors the product: the **viewer** creates a receive-only offer and `POST`s it to the host rig's listener; the host answers. Transport is a tiny HTTP/1.1 listener (`NWListener`, port 48731) on the host, bound to LAN interfaces and gated by the shared token as a bearer header. SDP goes over the LAN in plaintext exactly as the file exchange did; this is a trusted-LAN development convenience, not an authorization system, and the plan says so in `--help`.
- Reconnect loop on the viewer: on start, disconnect, ICE failure or HTTP error, wait 1 s (bounded backoff to 10 s) and offer again. The host tears down any existing session when a new offer arrives (single viewer, latest wins). Because both processes are `KeepAlive`, deploying either side re-establishes media within a few seconds without any operator action.
- Each side includes its git SHA, dirty flag and build configuration in the signaling exchange so the HUD can show what is actually running on both ends.
- Same-Mac fallback: `role: host` and `role: viewer` with `peer: 127.0.0.1` in two LaunchAgents gives a loopback rig when the second Mac is unavailable. The README's existing caveat applies: loopback establishes function, not LAN performance.

### Live HUD and streaming telemetry (removes the wait-for-the-report step)

- Viewer: a semi-transparent monospaced overlay in a sibling `NSView` above the Metal view (not inside the render pass), refreshed once per second from `ScreenSharingMetrics.snapshot()`, `peer.statistics()`, the mailbox/render-coordinator counters and the existing per-second `ScreenSharingRTCIntervalMetrics`. Rows: presented fps, largest update gap in the last second, decode p95, jitter-buffer delay, RTT, receive Mbps, decoded resolution, selected candidate pair (host/relay, protocol), active trials and profile using the existing requested/active label, both build hashes, uptime, reconnect count.
- Host: a small always-on-top status window or menu-bar title with capture fps, encoder p95, admission drops, keyframes, target bitrate and the adaptive-quality level.
- Toggle with `hud: false` or the `H` key. For formal image-age samples the HUD must be off or outside the observed content rectangle; the deploy script refuses `--sample` with the HUD on.
- The same one-second snapshot is appended as JSON Lines to `~/Library/Logs/CodevisorRig/<role>.jsonl` so existing analyzers get a stream instead of an end-of-run report. Rotation at 50 MB; no SDP, addresses or credentials in the file, matching the current report policy.
- Stretch: live cross-Mac image age. The SEI source marker already carries the capture timestamp and `ProbeClockSync` already provides calibration; the host rig runs the clock responder, the viewer calibrates every 60 s and shows "image age p50/p95 ±err". Displayed with its clock error; never shown without it.

### Workload and source (removes the shared-desktop dependency)

- `capture: workload:1920x1080@60` makes the host rig open the existing `ProbeOwnedWorkloadWindow` in-process and capture it, giving a deterministic source that no external session can change. `capture: display:<id>` keeps real-desktop runs available.
- Phase 5 adds `capture: virtual:<WxH@fps>`: create a `CGVirtualDisplay` (declarations after DeskPad's MIT header, runtime-checked with `NSClassFromString`, with a termination handler that falls back to `workload:`), place the workload window on it and capture that display. This isolates the rig from the physical desktop entirely and doubles as the virtual-display spike discussed for the product. Private API is acceptable in the rig; it is not a product commitment.

## Phases

| Phase                         | Deliverable                                                                                                                       | Exit criterion                                                                                                                                     | Estimate        |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| 0. Identity                   | Fixed bundle ID, Apple Development signing with ad-hoc fallback and warning, stable install path                                  | Two consecutive rebuilds produce an identical `codesign -d -r-` requirement; a Screen Recording grant made after build 1 still works after build 2 | done 2026-09-14 |
| 1. Rig mode                   | `--rig host/viewer`, `rig.json`, token-gated HTTP signaling, reconnect loop, build-hash exchange, loopback rig                    | Kill either process; media returns within 5 s with no operator action                                                                              | done 2026-09-14 |
| 2. Deploy                     | `rig:install`, `rig:deploy`, `rig:status`, `rig:stop`; LaunchAgent plist generation; remote atomic swap                           | `bun run rig:deploy --to <host>` from a clean edit to both Macs streaming in under 90 s, no System Settings or SSH shell                           | done 2026-09-14 |
| 3. HUD                        | Viewer overlay, host status, JSONL sink, `H` toggle, `--sample` guard                                                             | HUD numbers agree with the end-of-run JSON for the same interval; HUD off leaves presented-fps unchanged within noise                              | done 2026-09-14 |
| 4. Workload source            | `capture: workload` in-process; one-command sample (`rig:sample --seconds 60`) that turns HUD off, streams, and writes the report | A sample runs without touching the physical desktop and produces the same report shape as today                                                    | done 2026-09-14 |
| 5. Virtual display (deferred) | `capture: virtual`, fallback, sleep/lock/reconfigure survival                                                                     | Same sample works on a headless-style virtual display; results compared with `display:` capture for text fidelity                                  | 1–2 days        |

Phases 0–2 are the loop; 3 is where the "app" feel comes from; 4 removes the shared-desktop dependency. Phase 5 is deferred until the rig is in place; it is listed so the `capture:` source design leaves room for it. Total about one week of focused work for phases 0–4. Each phase lands separately and keeps every existing probe mode working.

## Boundaries

- The rig never ships, never signs with Developer ID, never installs on a machine that is not a development host, and never touches the installed product apps or their grants.
- The listener is LAN-only and token-gated; no STUN/TURN, no relay, no discovery beyond the configured peer. Bonjour can come later if addresses become annoying.
- Nothing in the rig changes product defaults, field trials or codec selection. Knobs are rig configuration, and any product change still goes through the existing plan and review.
- Existing measurement archives and their probe identities are not rebuilt, re-signed or moved.

## Validation

- Deterministic tests under `scripts/*.test.mjs` for argument parsing, plist and config generation, staging/swap path logic and the "no ad-hoc without warning" rule. No test performs SSH or launches an app.
- Swift tests for the signaling message codec, the reconnect state machine (bounded backoff, latest-offer-wins on the host) and the HUD formatter, all pure. Existing 180-test media suite and CoreMac suite stay green.
- Manual acceptance per phase as listed above, recorded once in `docs/measurements/screen-sharing-rig-<date>/README.md` with build hashes. This is a tool check, not a performance claim.

## Decisions

1. Roles (confirmed): tuftlord is the host, deployed over `ssh tuftlord@tuftlords-macbook-pro`; the local M4 Max is the viewer.
2. Wired path: the local Mac is currently on Wi-Fi (`.123` on `en0`). The rig does not select interfaces; an all-wired setup remains a physical prerequisite for parity numbers, not a rig feature.
3. Phase 5 (`CGVirtualDisplay`) is deferred (decided 2026-09-14): build the rig first, then revisit source optimizations.

## Phase 0 record (2026-09-14)

`bun run screen-sharing:rig` builds `tmp/screen-sharing/ScreenSharingRig.app`, signs it with the login keychain's Apple Development identity (`scripts/screen-sharing-bundle.mjs` selects it; `CODEVISOR_RIG_SIGN_IDENTITY` overrides; ad-hoc only with a printed warning) and installs it atomically to `~/Applications/CodevisorRig/`. The existing probe script is unchanged.

Verified: a release build, a debug build and a second release build (CDHash `7d748aaf…`, `2160909d…`, `7d748aaf…`) all report the same designated requirement, `identifier "com.codevisor.ScreenSharingRig" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …" and certificate 1[field.1.2.840.113635.100.6.2.1]`. Because the requirement pins the certificate's common name, the grant will need renewing once when that certificate is replaced (roughly yearly); a team-based explicit requirement can replace this later if that becomes annoying. First build took 31 s; the rig has not yet been launched, so no TCC grant exists yet — that happens on the first capture in Phase 1.

## Phases 1–4 record (2026-09-14)

Layout changed from the first draft: the rig is its own executable, `screen-sharing-rig`, under `packages/swift/ScreenSharingRig/` (`ScreenSharingRigKit` library + executable + tests), consuming `CodevisorScreenSharing`. The workload window, painter and synthetic source the probe and rig share moved out of the probe executable into a `ScreenSharingDiagnostics` library with `package` access. The probe is otherwise unchanged. See the [rig README](../../packages/swift/ScreenSharingRig/README.md).

Same-Mac loopback (debug build, synthetic 1080p60 source): host and viewer connected within 1 s of launch; steady state 57.9 presented / 59.8 decoded fps at 10.2 Mb/s with 38 ms jitter-buffer mean and zero decode errors; `POST /sample` for 5 s returned six samples (mean 57.1 fps) and a report carrying the host's snapshot; killing the host and restarting it reconnected the viewer on a new session with no operator action (~14 s, dominated by WebRTC's consent timeout; the host-status probe added afterwards removes the 5 s grace from that).

Two-Mac (release build, tuftlord host with `workload:1920x1080@60`, local viewer): `install` from a clean edit to both agents running took 19–34 s including the release build and `rsync`. The host started cleanly. The viewer was blocked by macOS's Local Network privacy gate on the first LAN connection (`NSURLErrorDomain -1009`, "Local network prohibited"), which is a one-time grant per Mac for the fixed identity; the remaining two-Mac checks (media, sample, restart-reconnect through `launchctl kickstart -k`) follow that grant.

Tests: 25 `ScreenSharingRigKitTests` (pure, plus one loopback socket test on an OS-chosen port), 180 media tests unchanged, 50 script tests. Deterministic: no sleeps, no fixed ports, no real clocks in assertions.

## Two-Mac verification (2026-09-15)

After the Local Network grant on the viewer Mac (System Settings → Privacy & Security → Local Network → ScreenSharingRig; tuftlord needed none), the pair connected and stayed connected: tuftlord captured its owned workload window at 1920×1080@60 with no Screen Recording grant; the viewer decoded 53–56 fps at 9.5 Mb/s over a direct `host/udp→host` pair with 3 ms RTT, 52 ms jitter-buffer mean, 2.2 ms mean decode, zero decode errors, zero NACK/PLI. `bun run screen-sharing:rig sample --seconds 10` produced ten per-second samples plus the host's snapshot in one report.

Restart: `launchctl kickstart -k` of the host agent on tuftlord to a new live session on the viewer took 10 s, with the host-status probe ending the old session immediately ("host no longer has this session") instead of waiting out the grace period.

Deploy loop: an edit to the HUD formatter, `bun run screen-sharing:rig deploy`, to both Macs running the new build with media re-established took **13 s** (incremental release build, signing, `rsync`, `kickstart` on both). The agents restart local-first, so the viewer briefly connects to the old host process and reconnects once more after the host restart; steady state followed within seconds.

One finding from the run: with the viewer window fully covered or hidden, macOS presents no drawables, so `presentedFrames` does not advance while decoding continues. The metric is correct (only a positive `presentedTime` counts); the HUD now says "presented — (window not on screen)" in that state, and the sample report carries `unpresentedDrawablesPerSecond` so an occluded sample is recognisable after the fact.

Not covered by this run: control input, clipboard, Screen Recording of a real display (`display:` capture), sustained multi-hour operation, and any performance claim. This is a tool check; the numbers describe the rig's own path and are not a benchmark.

## Phase 5, step 1: virtual display source (2026-09-15)

`capture: virtual:WxH@fps` creates a display through CoreGraphics' private `CGVirtualDisplay` (declarations in `packages/swift/ScreenSharingRig/Sources/CGVirtualDisplayPrivate`, derived from DeskPad's MIT header; the classes are exported by `CoreGraphics.tbd`, so they link normally), waits for AppKit to attach the screen, places the workload window on it and captures the display. It is rig-only and behind the same Screen Recording grant as `display:`; the wrapper is `RigVirtualDisplay`, released with the session, which removes the display.

Verified on the local Mac (macOS 27.0, loopback host + viewer): the display comes online in under a second as "Codevisor Rig Display" at backing scale 2.0 (the HiDPI shape Apple's own Screen Sharing virtual display reports). `virtual:1920x1080@60` creates a 960×540 pt display whose 1920×1080 px raster equals the video raster, the workload window fills it above the menu bar, and capture is 1:1; the first attempt used 1920×1080 pt (3840×2160 px) with the workload in one quarter, which streamed fine but is not the comparison we want. Media through it: 56–58 fps captured and decoded at 10.4–10.9 Mb/s, 21–23 ms jitter-buffer mean, encode p95 8.1 ms, zero decode errors over an 11-sample run; the physical display on the same session gave 58.6 / 57.7 fps at 1.6 Mb/s (a static desktop). The termination handler and sleep/lock/reconfigure survival are not yet exercised; the two-Mac run on tuftlord needs the Screen Recording grant there.

A trap found on the way, matching the note in the September 11 Apple comparison: `replayd` leaks about two pipe descriptors per ScreenCaptureKit stream on this Mac (246 pipes when capture went silent; nine after four sessions on a fresh process). At its file limit, SCK starts a stream and delivers no frames and no error, for physical and virtual displays alike. `launchctl kickstart` is refused under SIP and SIGTERM is ignored; `kill -KILL` on the user's `replayd` makes launchd respawn it and capture resumes. The rig should surface "stream started, no frame within N seconds" as a distinct state rather than silence; that is the next tool change.

## Phase 5, step 2: application and window sources, live switching (2026-09-15)

`capture: app:BUNDLE` captures every on-screen window of one application through `SCContentFilter(display:including:)`, and `window:ID` one window through `desktopIndependentWindow`; both need Screen Recording. `POST /source {"capture": SPEC}` on the host (CLI: `screen-sharing:rig source SPEC`) stops the current source and starts the new one on the same session: the peer, its negotiated 1920×1080 encode size and the viewer are untouched, so consecutive `sample` runs on different sources share one session and one network moment. A switch that fails (unknown bundle, missing window, no grant) restores the previous source and reports the error; without a live session the new source applies to the next one.

Loopback run on the local Mac: synthetic (59.9 fps) → workload (57.5) → virtual (46.4 in its first seconds) → synthetic (59.7), plus application and window capture of the rig viewer itself, all on one session with zero decode errors; an `app:` switch to a bundle that was not running was refused and the workload source resumed. Sources remain host-side configuration selected by name; the viewer never learns which is active except through the host's status, mirroring the product boundary.

Two-Mac virtual display (2026-09-15): after the Screen Recording grant on tuftlord, its host created a virtual display (960×540 pt at 2×), captured it with the workload window and the local viewer decoded 56–57 fps at 10 Mb/s over 3 ms RTT with zero decode errors, on the same direct path as the owned-window run. Granting Screen Recording to a running app makes macOS quit and reopen it; the host exited cleanly and the LaunchAgent, which only restarted abnormal exits, left it down until a manual `kickstart`. The host agent now restarts on any exit; the viewer keeps close-to-stop.

## Phase 5, step 3: comparison on one session, stall detection (2026-09-15)

With live switching, `workload:` and `virtual:` were sampled for 20 s each on the same tuftlord → viewer session: workload 56.2 fps decoded mean (min 53.1) at 10.3 Mb/s with a 64.5 ms jitter-buffer mean, host capture 55.9 fps; virtual 53.7 (min 49.4) at 10.0 Mb/s with 57.1 ms, host capture 52.1 fps; encode p95 8.9 ms and zero decode errors in both. A virtual display costs about two to three frames per second of capture cadence against owned-window capture of the same content, and buys nothing in fidelity here because both rasters are already 1:1; its value is independence from the physical desktop (and, for the product, headless hosts), not speed. Single samples, same minute, same direct path; not a benchmark.

The host now watches each source start: no captured frame within 5 s sets a `sourceStall` label, logs it, and the host HUD and samples show it, so an exhausted `replayd` reads as "STALL: no frames 5 s after … started" instead of a silent "— fps". `install` writes the host plist with restart-on-any-exit (the earlier change had not reached the remote call), and `sample --report` accepts relative paths.

## Phase 5, step 3b: display sleep (2026-09-15)

`pmset displaysleepnow` on tuftlord while it streamed its virtual display: ScreenCaptureKit stopped the stream within a second with "Failed to find any displays or windows to capture" — for the virtual display as much as a physical one — and never resumed on wake; the WebRTC session stayed connected at 0 fps. The rig host now holds a `PreventUserIdleDisplaySleep` assertion while a session is live (an explicit `displaysleepnow` still sleeps the displays; idle sleep no longer does) and, when the capture records an error, re-applies the active source every 5 s until one starts. Measured: error noticed at +1 s, three refusals while the displays slept (`CGVirtualDisplay` rejects its mode then), restart within a second of wake, viewer back at 59 fps three seconds after the wake command. A product host needs both behaviours whatever its source.

## Phase 5, step 4: what this says about a product virtual-display mode

Viable, with conditions. `CGVirtualDisplay` creates a HiDPI display on macOS 26.6 and 27.0 in under a second; ScreenCaptureKit captures it like any display; it goes away when its object is released; the classes are exported by the SDK stub, so linking is ordinary and the runtime guard (`NSClassFromString`) is the only defence needed against a future removal. Costs and limits found here: it needs the Screen Recording grant (only owned-window capture avoids that), it captures two to three frames per second slower than an owned window of the same content, and it does not survive display sleep any better than a physical display, so a host must prevent idle display sleep and restart capture on error. Not yet answered, and the question that matters most for headless hosts: whether creation works on a Mac with no display attached at all — both test Macs have built-in panels, so every run so far had a physical display present. That is the next experiment if headless hosts are a product goal (a Mac mini, or a MacBook in clamshell with no external display), and it is cheap with the rig: `install` there with `capture: virtual:` and read the host log.

Recommendation: keep the private API out of the product library and out of the MVP; if headless hosts become a goal, add a product `virtual display` source behind an explicit setting with a visible fallback to the physical display, and adopt the sleep assertion and error-driven capture restart regardless of source, since those fix failures a physical-display host has today.

`virtual-desktop:WxH@fps` (2026-09-15) is the same display left bare: on tuftlord the viewer showed the virtual display's own wallpaper and menu bar at about 1 fps, ScreenCaptureKit delivering frames only when the static desktop changed, with 3 ms RTT and no errors. Windows moved onto "Codevisor Rig Display" on the host stream through it; the `app:` and `window:` sources remain the way to stream a specific application without touching its display arrangement.

## Live image age (2026-09-15)

The viewer now shows the metric the parity work is about. The host answers `GET /clock` with its `CACurrentMediaTime` receive and send stamps; the viewer brackets 25 such exchanges with its own clock, keeps the tightest `[hostSent − t1, hostReceived − t0]` interval as the `host − viewer` offset (no symmetry assumption; the half-width is the stated error) and recalibrates every 60 s. The renderer gained an additive `onFramePresented` hook carrying each presentation's clock values and the frame's in-band capture timestamp, and the decoded identity now rides the decoded buffer to the renderer as it rides the captured buffer to the encoder. Image age = presented time − (capture timestamp − offset); the HUD shows p50/p95/max per second with the clock error and frame count, and samples carry the same summary.

First two-Mac reading (tuftlord virtual display → local viewer, direct path, 3 ms RTT): p50 45–104 ms, p95 45–104 ms, max 62–137 ms, ± 4.3 ms, about 50 measured presentations per second, quantised to 60 Hz steps because both capture and presentation are frame-locked. That is the same band as the calibrated offline measurement (median 135 ms, p95 167 ms at 4K on September 11) and it now updates once a second after a 13-second deploy. Capture timestamp to on-screen presentation only: not input-to-photon, and the viewer window must be on screen for any presentation to exist.

## Tuning knobs (2026-09-15)

`rig.json` accepts a `tuning` object — `profile: paced15-worker` (the product's diagnostic profile, as a base), `playoutDelayMs: [min, max]`, `jitterWindowFrames`, `renderOnArrival`, `drawables`, `offMainPreparation`, `captureIntervalFPS` — applied at process start: the WebRTC trials through the same process-wide boundary the product uses, the renderer options through `ScreenSharingMetalView`, the capture request through `ScreenSharingCapture`. `rig tune JSON|paced15-worker|default` rewrites both configs and restarts both agents without a rebuild; measured 2.7 s from the command to both agents running with the new tuning, and both ends publish the trial actually installed (`playoutExperiment`) so the HUD's tuning label cannot claim a selection that did not take. First reading on the tuftlord virtual-display session: defaults p50 45–104 / max ≤137 ms, `paced15-worker` p50 40 / p95 73 / max 82 ms, ± 4 ms — single samples a few minutes apart, but the loop that makes a real comparison cheap now exists.

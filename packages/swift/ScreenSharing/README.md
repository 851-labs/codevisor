# Screen sharing

The engine behind the Screen Sharing pane, in three targets under `packages/swift/ScreenSharing`:

| Target | Links | Holds |
| --- | --- | --- |
| `ScreenSharing` | CZlib, system frameworks | `Session/` (viewing-session and message-channel contracts), `Messages/` (input, control, clipboard, refresh), `Frames/` (frame, mailbox, sink, identity), `Metrics/`, `Capture/` (ScreenCaptureKit, the source idle monitor), `Codecs/` (VideoToolbox encoder and decoder), `Render/` (the Metal view and coordinator), `Viewer/` (the AppKit surface: video, input capture, forwarder), `HostInput/` (control lease, CGEvent injection), `RFB/` (the VNC wire protocol), `VNC/` (VNC as a viewing session), `Diagnostics/` (the default-off profile, delivery audit) |
| `ScreenSharingWebRTC` | `ScreenSharing`, WebRTC | `Peer/`, `Channels/` (data channel, frame sender), `Endpoints/` (sender, receiver, recovery), `Codecs/` (the factory bridging VideoToolbox into WebRTC), `FieldTrials/`. The only target that links the binary framework. |
| `ScreenSharingTesting` | `ScreenSharing` | The in-process RFB server the suites and the rig drive. Never a dependency of a product target. |

Folders are layers; targets are dependency edges. `ScreenSharing` cannot reach WebRTC because it does not link it, so the VNC session, the viewer surface and every test of those parts never load the framework. `Viewer/`, `HostInput/` and `VNC/` are macOS-only (`#if os(macOS)`); the rest compiles for iOS. Product feature code (the Composable Architecture reducer, the backends and runners, the host service) stays in `CodevisorCoreMac/ScreenSharing`; the rig under `apps/screen-sharing-rig` links all three targets.

## Native Screen Sharing

Implementation of [the Screen Sharing plan](../../../docs/plans/native-screen-sharing.md): a native media library, a diagnostic app, and a native macOS workspace pane with authenticated signaling and explicit remote control. No HTTP plugin server or webview participates in video delivery.

The working path is ScreenCaptureKit (or a synthetic motion source) → native WebRTC video source → custom VideoToolbox H.264 encoder → encrypted WebRTC media → custom VideoToolbox decoder → CVPixelBuffer-backed Metal textures. The custom codec factories are used by WebRTC itself; frames are not encoded twice.

## Native workspace pane

Run `bun run dev:macos`. In a workspace hosted by a Mac, open New Tab → Screen Sharing and select a display from the searchable chooser to connect. The host must run this version of the native app and allow Screen Recording. The native toolbar shows the machine name and resolution, View/Control, clipboard and connection details. The video always scales to fit the pane. Closing the tab ends the session. iOS preserves the pane and shows an unavailable state until its viewer milestone.

The viewer sends a receive-only offer through the existing machine-authenticated, relay-aware client to `POST /v1/screen-sharing`. The server validates the active workspace and native pane, then forwards the request over Codevisor’s authenticated Unix bridge to the app’s native host service. SDP stays transient; only the stable display UUID and fit preference enter pane metadata. Synced size preferences update the existing native surface; a display change from another client requires a fresh Connect. Websites are rejected even on loopback.

One viewer owns the host at a time. Capture begins after its peer connects. The host shows a menu-bar Sharing indicator with Stop Sharing. An eight-second heartbeat renews a 25-second lease; loss of the viewer stops capture. Sleep, session deactivation, display changes and SCK errors also stop it. A connection without video ends after three heartbeat intervals, and decoder failures end viewing on the next heartbeat. Hiding or closing the viewer tears down media; returning to a previously connected tab renegotiates. A newer negotiation waits for the old stop request, and generation checks reject late frames and signaling responses. Reopening the app requires an explicit Connect.

The current host scales to fit 1920×1080, preserving aspect ratio, at up to 60 fps / 12 Mbps. Direct ICE is the default. Optional host-configured STUN/TURN supports other routes; the existing cloud channel still carries signaling only. See connectivity configuration below.

## Native control

New panes start in **Control** mode and request control when video and the data channel are ready. The selector stays interactive while connecting; choosing **View** cancels that pending request. The selected mode survives menu interactions and reconnection. The host also needs Accessibility permission (called Device Control and Data Access in macOS 27). **Control–Option–Escape** returns to View. Clicking outside the video or losing keyboard/window focus suspends input forwarding and releases held input without changing the selected mode. Hiding or closing the pane, disconnecting, and the host’s Stop Sharing action tear down the connection and its control lease. The host indicator changes to “Controlled” while a control lease is active.

A fresh host-issued control lease binds input to the current authenticated WebRTC peer and selected display. One-second heartbeats renew a separate three-second control deadline, checked every 250 ms. Expiry, permission loss, malformed messages and channel closure revoke the lease and release tracked keys/buttons. Delayed grants are released after viewer cancellation; input from an expired lease cannot revive control. No control lease, input or key content enters pane metadata or logs.

The native ordered data channel carries key/button transitions, scroll deltas and motion. A 16 ms viewer tick coalesces waiting motion; transitions flush it first to preserve ordering. Each button event contains its own normalized coordinates. The send queue admits at most 16 KiB, and the receive queue at most 256 messages / 64 KiB; congestion or invalid input closes control instead of accumulating actions. This first implementation deliberately uses one reliable ordered channel. A separate unreliable motion channel needs button-generation coordination before it can replace this ordering contract.

The native surface maps through fit-to-pane letterboxing and backing-pixel scale. The host maps normalized coordinates into Quartz display bounds, including negative origins. It uses public CGEvents from a private event source, with no automation delays or app activation. Tagged injected events are excluded from capture by a viewer on the same Mac. Fractional trackpad deltas accumulate before conversion to integer pixels.

Physical Mac key codes use the host’s keyboard layout and input method. With viewer Accessibility permission, a focused video surface in Control mode forwards system shortcuts such as Command-Space and Command-Q. Basic physical typing, modifiers, repeat, mouse buttons, dragging and scrolling are implemented; automatic clipboard synchronization, a local cursor overlay and dedicated Unicode composition UI remain follow-up work. Explicit plain-text clipboard transfer is available from the toolbar. The protocol has a bounded, separate text-insertion message exercised by the diagnostic sink. Rotated/external-display mapping, non-US layouts, IME behavior and the complete final-source two-Mac acceptance checklist still need hardware validation.

## Clipboard, cursor and connection details

The clipboard menu explicitly sends or retrieves plain text, up to 64 KiB of UTF-8. A separate ordered SCTP channel carries 2 KiB chunks with stop-and-wait acknowledgments; it cannot fill the keyboard/mouse channel. Transfers expire after ten seconds, reject invalid or incomplete UTF-8, and discard partial data on cancellation. A download cannot replace a newer local copy made while it was in flight. There is no automatic polling, file transfer, rich text, or clipboard persistence in signaling, logs or the workspace database.

ScreenCaptureKit includes the host cursor in video. AppKit cursor rectangles suppress the viewer cursor only inside the active control surface and restore the local arrow on release/exit. Apple's current SDK deprecates `NSCursor.currentSystem`, so this implementation uses the supported captured-cursor fallback rather than a cursor-shape stream. Same-Mac loopback cannot establish independent host/viewer cursor fidelity.

Connection Details shows the selected direct/relay route, transport, decoded resolution, interval presentation rate, receive bitrate, round-trip time and decode p95. It omits SDP, addresses and credentials. Statistics run separately from the control heartbeat.

## Connectivity and recovery

The native host reads optional deployment configuration from its launch environment:

| Variable | Meaning |
| --- | --- |
| `CODEVISOR_SCREEN_SHARING_STUN_URLS` | Comma-separated `stun:` or `stuns:` URLs |
| `CODEVISOR_SCREEN_SHARING_TURN_URLS` | Comma-separated `turn:` or `turns:` URLs, optionally `?transport=udp` or `?transport=tcp` |
| `CODEVISOR_SCREEN_SHARING_TURN_SECRET` | Host-only TURN REST shared secret; never shipped in the viewer |
| `CODEVISOR_SCREEN_SHARING_RELAY_ONLY` | `1` forces a TURN route; default `0` allows direct connections |

With no configuration, neither peer contacts a third-party ICE server. The host mints five-minute, viewer-specific TURN REST credentials using HMAC-SHA1. The viewer requests fresh credentials immediately before negotiation through the authenticated, uncached machine API. This matches [coturn's TURN REST mechanism](https://github.com/coturn/coturn/blob/master/README.turnserver#turn-rest-api). A deployed TURN service and forced-relay/UDP-restricted network verification remain required; no relay infrastructure or fixed client secret is included here.

After an established connection drops, the viewer releases input, discards the old native peer and its frame mailbox, and renegotiates using `restart`. The host accepts replacement only for the same still-live viewer lease and display. Host stop, sleep, display change, cancellation and lease expiry prevent renewal. Replacement uses fresh ICE/DTLS and codec state rather than restarting ICE inside the old peer; control must be requested again. Three automatic replacements are allowed before explicit reconnect is required. This avoids replaying queued input or decoder state across routes.

The host polls WebRTC's selected candidate-pair bandwidth estimate once per second. Two seconds of insufficient bandwidth lowers one quality step: full resolution at 60 fps → full resolution at 30 fps → 75% dimensions at 30 fps → 50% dimensions at 20 fps. Fifteen seconds of sustained headroom restores one step. Capture and the native source change together; old-size raw frames are discarded before encoding. Coordinates remain normalized to the original display. Missing estimates leave the current quality unchanged. This policy has live format-transition checks; tuning against real congested networks is still pending.

## Latency and codec investigation

The [tuftlord report](../../../docs/measurements/native-screen-sharing-tuftlord-2026-09-10/README.md) records hardware codec experiments and native WebRTC runs in both directions between an M1 Pro and M4 Max. Hardware HEVC 4:4:4 works through the public VideoToolbox APIs, including direct BGRA input when selecting the Main444 value returned by the supported-property query. The low-latency rate-control flag changed tested NV24 input to 4:2:0, so output format must be verified.

The probe now samples receive-buffer/processing/codec/send-delay interval means from WebRTC cumulative counters and records receiver-local callback-to-submission/presentation timings. It never subtracts clocks on different Macs. Only positive Metal `presentedTime` values count as new on-screen frames; skipped drawables and redraws are excluded. A historical callback-counting error is corrected in the earlier report.

`--render-on-arrival` enables an experimental bounded renderer driven by mailbox availability. It improved frame rate and median renderer delay in the two-Mac runs but worsened p95, so the native app retains its display-link default. `--keep-front` makes diagnostic visibility explicit. These results do not establish input-to-photon latency or Apple High Performance parity.

`--standard-rate-control` compares standard VideoToolbox rate control with the default low-latency rate controller in a sending or loopback probe. The default codec is hardware H.264 without frame reordering and with at most two admitted frames. Explicit probe flags can select HEVC or change this admission bound. The native app keeps the low-latency default. The [timing investigation](../../../docs/measurements/native-screen-sharing-timing-2026-09-11/README.md) records local comparisons and the blocked tuftlord desktop follow-up. No additional encoder-internal frame-delay cap is claimed: the tested encoder rejects `MaxFrameDelayCount`.

Cadence diagnostics now distinguish capture/source timestamps, arrival at the native source, encoder input, the duration of the VideoToolbox submit call, encoded output, decoder input and the receiver callback. Capture delivery age uses SCK's timestamp and the Core Media host clock; it is absent from synthetic runs. These bounded per-stage measurements supplement the existing RTC buffer/send-delay statistics. The probe retains only numeric counts from WebRTC's periodic encoder drop log. Decoder input occurs after WebRTC buffering and is not a packet-arrival timestamp.

```sh
bun run screen-sharing:probe --instance codecs --check-codecs --report tmp/screen-sharing/codecs.json
bun run screen-sharing:probe --instance codecs --check-codecs --codec-case hevc-advertised444-bgra --width 3840 --height 2160 --bitrate 75000000 --report tmp/screen-sharing/codecs-4k.json
```

`--check-codecs` is a standalone VT experiment with matching source/decoded images in `<report>.images`; it does not enable HEVC in the product. The expanded measurements passed 1,788 Swift tests, strict media lint/format checks, and both native app builds.

The follow-up [real-desktop runs on tuftlord](../../../docs/measurements/native-screen-sharing-tuftlord-2026-09-10/README.md#real-desktop-native-media-runs) verify ScreenCaptureKit capture at 1080p and 4K and expose more WebRTC receive buffering than the synthetic workload. They also record the shared Apple High Performance workload, a CoreText correction for the diagnostic header, and the limits of the exploratory renderer comparison. Probe packaging now isolates identities by worktree and instance; the approved remote capture copy remains usable alongside the separately updated workload app.

The [September 11 Apple High Performance comparison](../../../docs/measurements/native-screen-sharing-apple-2026-09-11/README.md) uses the same recording method and viewer content size for both 4K streams. Two retained recordings per viewer observed 53.9 updates/s for Apple and 38.9–39.7 for Codevisor; a local recording control observed 57.4 at a requested 60 fps. These are sampled updates, not physical FPS or input-to-photon latency. Codevisor's approximately 26 ms encoder p95 and 115–145 ms receive-buffer weighted means identify further profiling work. The shared network and Apple's concurrent virtual-display stream limit the comparison.

## Run the diagnostic app locally

From the repository root, on macOS 26 or later with Xcode and Bun installed:

```sh
bun run screen-sharing:probe --loopback --duration 10 --report tmp/screen-sharing/loopback.json
bun run screen-sharing:probe --capabilities
bun run screen-sharing:probe --list-displays
bun run screen-sharing:probe --loopback --display 1 --duration 10
```

Additional checks:

```sh
# Live resolution/frame-rate changes; add --display ID to exercise SCK.
bun run screen-sharing:probe --instance quality --loopback --check-quality --duration 10
# Resource timeline: also writes <report>.progress.json every 30 seconds.
bun run screen-sharing:probe --instance endurance --loopback --duration 1800 --report tmp/screen-sharing/endurance.json
# Actual native host API; use an existing, disconnected Screen Sharing test pane.
bun run screen-sharing:probe --instance host --check-host http://127.0.0.1:59372 --workspace WORKSPACE_UUID --pane PANE_UUID
```

Loopback checks both ordered input/release and bidirectional chunked Unicode clipboard delivery with recording/in-memory sinks; they do not post OS input or access system clipboards. `--check-host` verifies video, rejects replacement from another viewer, replaces the authorized media peer, and verifies that a stopped lease cannot restart. It requires the running development app. Supply an optional API token only through `CODEVISOR_SCREEN_SHARING_PROBE_TOKEN`; remote host checks require HTTPS.

Use the display ID returned by `--list-displays`. Display capture requires Screen Recording permission. The probe fails with an explanation when preflight permission is absent. Synthetic mode needs no screen capture permission. Local Network permission and firewall settings must allow the probe to connect.

Defaults are 1920×1080, 60 fps, and a 12 Mbps bitrate ceiling. Options include `--width`, `--height`, `--fps`, `--bitrate`, `--duration` (1–3600 seconds), and `--report`. Use `--help` for details. The default synthetic source animates lines and a rectangle below color bars; it is a lightweight transport workload, not a text-fidelity or worst-case bitrate benchmark.

Synthetic input defaults to **BGRA**, while ScreenCaptureKit supplies video-range **NV12**. Use `--synthetic-format nv12` to convert the same generated image with a bounded NV12 pool before passing it to WebRTC. Reports record the actual source pixel-format code, conversion time and total source preparation time; conversion work is moved outside the encoder measurement, not eliminated. `--synthetic-format bgra` reproduces the original input path. These options apply only to generated sender/loopback traffic and also work with quality transitions. Codec-only comparisons use `h264-low-delay-nv12` and `h264-realtime-nv12`, with conversion reported separately and included in the decoded-frame fidelity result.

The [pixel-format investigation](../../../docs/measurements/native-screen-sharing-pixel-format-2026-09-11/README.md) records two trials for each input/controller combination. Standard mode improves the lightweight NV12 media workload, while low-latency mode wins the isolated NV12 colored-text codec test. Real-desktop measurements remain necessary before selecting a different product default.

The build command (`bun run screen-sharing:probe`, which runs the rig executable's `probe` subcommand) creates `tmp/screen-sharing/ScreenSharingProbe.app`, embeds WebRTC and its resource bundle, fixes the framework search path, and signs the diagnostic app ad hoc. `--build-only` builds without launching. The resulting binary is at `ScreenSharingProbe.app/Contents/MacOS/screen-sharing-probe`; invoke it directly to rerun without rebuilding. Close the window to stop a viewer early.

Use `--instance NAME` to build a separately named diagnostic app without replacing another running probe. The bundle identifier is stable for each worktree/instance pair and differs between pairs, so Launch Services and permission entries cannot confuse distinct diagnostic instances. Grant capture permission separately for each identity. Previously built probes retain their old identity until rebuilt.

The helper builds for the current Mac's architecture. Build on the other Mac too, or copy the app to another Mac of the same architecture. The bundle is a local diagnostic artifact, not a notarized release. The default and file-signaling modes have no dependency on the Codevisor server or a running development app.

### Capture permission and a shared desktop workload

Finish building before granting Screen Recording permission. Ad-hoc signing can tie the grant to the executable's code hash, so rebuilding can invalidate it. Keep the final copy at a stable location such as `~/Applications/CodevisorDiagnostics/ScreenSharingProbe.app`, launch that copy through Launch Services, and grant it access under **Privacy & Security → Screen & System Audio Recording**. If an enabled entry still refers to a previous build's signature, remove that diagnostic entry with the minus button before adding the final copy; adding over the existing entry may retain its old code requirement.

```sh
open -n -W ~/Applications/CodevisorDiagnostics/ScreenSharingProbe.app \
  --args --request-screen-recording --duration 120
open -n -W --stdout /tmp/screen-displays.log --stderr /tmp/screen-displays.err \
  ~/Applications/CodevisorDiagnostics/ScreenSharingProbe.app --args --list-displays
```

The permission command requests access without starting capture and keeps the app alive for up to `--duration` seconds. Relaunch after macOS requests it, then inspect the display-list output and error log; `open` exiting successfully does not establish that the probe passed. When invoking a remote probe over SSH, use this Launch Services form for capture too: directly executing its binary can attribute the request to the SSH daemon instead of the diagnostic app.

`--show-workload` provides a common native desktop target for Codevisor and Apple's viewer. It displays scrolling colored text, motion, an 18-bit time-driven frame code and a response counter that changes when the window receives a click or a non-repeating key press. It closes itself after the requested duration, needs no capture permission and injects no input:

```sh
open -n -W ~/Applications/CodevisorDiagnostics/ScreenSharingProbe.app \
  --args --show-workload --width 3840 --height 2160 --fps 60 --duration 60 \
  --report /tmp/screen-workload.json
```

Run the workload on the sending Mac and view its desktop with the transport under test. Match the raster to the display's backing pixels, and use the same capture resolution, refresh rate and viewer scale in both runs. A Retina display at 1920×1080 points can have a 3840×2160 backing raster. The report records raster dimensions, window points, backing scale, AppKit draw calls and received-event times. Draw calls and the frame code are not physical presentation measurements; input-to-photon timing still needs an external recording or a calibrated method with stated error.

## Optimized pipeline experiments

Use `--release` on the build wrapper for performance runs. The report records the build configuration. `--codec hevc` and `--codec hevc444` select the codec on both peers; Main444 sending requires `--standard-rate-control` and BGRA source input. HEVC profile, bit depth and chroma are checked from the encoded format, and Main444 decoding must produce full chroma.

`--capture-picker` selects a display through macOS's scoped sharing picker. It is separate from the persistent Screen Recording permission used by `--display`. New ad-hoc probe identities can use that picker without replacing the previously approved diagnostic app.

`--desktop-pattern` draws the same text, scrolling pattern and time-driven marker as `--show-workload`, directly into the synthetic source. It isolates capture from the rest of the pipeline; it does not reproduce WindowServer or ScreenCaptureKit scheduling. Inspect source preparation and arrival timings before treating a run as a steady 60 fps source. `--user-initiated-activity` holds a Foundation user-initiated activity only during the finite media probe and allows idle system sleep; reports label whether it was requested.

`--prioritize-encoding-speed` requests the public speed-over-quality property with standard rate control. `--complete-each-frame` drains VideoToolbox through each submitted timestamp. Both are diagnostic options, and the synchronous-drain experiment reduced throughput in the current Main444 trial.

`--keyframe-interval N` changes periodic keyframes from the default two nominal seconds to 1–60. It sets a frame count using the configured FPS, so lower actual encoding throughput can lengthen the wall-clock interval. Requested keyframes still use the existing force-keyframe path. Reports split encoded frame/byte counters into keyframes and delta frames. Longer intervals need recovery validation before product use.

The [pipeline report](../../../docs/measurements/native-screen-sharing-pipeline-2026-09-11/README.md) records frame-arrival rendering, receive-buffer, capture-format, encoder-admission, codec and rate-control investigations. These remain explicit diagnostic options; successful HEVC transport is not a 4K60 or Apple-parity claim. `--help` lists experiment bounds and incompatible combinations. Keep both peers' codec selections equal.

## Two-Mac LAN workflow

Build the probe on each Mac. Choose fresh signaling filenames for every session. On the sending Mac:

```sh
ScreenSharingProbe.app/Contents/MacOS/screen-sharing-probe probe \
  --send --offer /tmp/screen-offer.json --answer /tmp/screen-answer.json \
  --duration 30 --report /tmp/screen-sender-report.json
```

Add `--display ID` for a real display. Otherwise the sender generates synthetic motion. Transfer the offer to the receiving Mac over a trusted channel such as authenticated SSH, then run there:

```sh
ScreenSharingProbe.app/Contents/MacOS/screen-sharing-probe probe \
  --receive --offer /tmp/screen-offer.json --answer /tmp/screen-answer.json \
  --duration 30 --report /tmp/screen-receiver-report.json
```

Return the answer to the sender. When transferring into a filename the probe is waiting for, copy to a temporary filename and rename after the transfer completes. The sender waits up to 120 seconds for the answer. Both peers begin their measurement interval after connecting. Setup failures, absent media, and codec/render errors produce a nonzero exit code. A passing report confirms media delivery; it does not enforce performance targets.

The probe writes complete signaling files atomically with mode `0600` and refuses to overwrite an existing session. SDP includes connection credentials and network addresses: exchange it privately and remove it afterward. JSON reports exclude SDP, IP addresses, and credentials. File exchange is a diagnostic replacement for the authenticated Codevisor signaling channel; it is not an identity or authorization system.

The file-signaling probe configures only host ICE candidates. There are no STUN/TURN services, cloud relay credentials, automatic discovery, or VNC interoperability. Check the nominated candidate's protocol in the reports to verify the actual route. Two peers in one process, or two processes on one Mac, do not establish LAN performance.

## Ownership and limits

- Capture callbacks feed WebRTC on the capture queue, without per-frame main-actor tasks. SCK uses a queue depth of three; the synthetic pool allows six outstanding surfaces.
- Hardware acceleration is required at VideoToolbox session creation. Software fallback is disabled. On this Mac, the low-latency encoder omits the optional hardware-status query; reports distinguish that from a confirmed query. The decoder's query returns true.
- H.264 constrained baseline, no B-frame reordering, 8-bit NV12/4:2:0, BT.709 SDR. Input dimensions are even and bounded to 3840×2160; the target frame rate is at most 60. These are supported configuration limits, not measured performance guarantees.
- WebRTC handles packetization, congestion feedback, pacing and keyframe requests. Bitrate updates reach VT; the native host adapts capture resolution/frame rate as described above. HEVC negotiation and 4:4:4 are future work; the [rig's keyframe/pacing record](../../../docs/plans/screen-sharing-rig.md) shows that 4:4:4's periodic stalls are the pacer draining large keyframes at 2.5 × the 12 Mbps target, removed on the LAN by a higher `WebRTC-Video-Pacing` factor or a longer keyframe interval.
- The encoder admits at most two pending raw frames. VT owns each output callback's immutable metadata. The decoder runs synchronously on WebRTC's decoder queue. These bounds describe Codevisor-owned stages; WebRTC also has internal queues and jitter buffering.
- Rendering has a one-frame mailbox, one command buffer in flight, and one retained last frame for resize redraw. Slow consumers replace stale waiting frames. CVPixelBuffers and their Metal textures survive until the GPU completes its reads.
- The peer and capture owner must call `close()` / `stop()`. Closing the peer stops capture-frame admission and remote rendering before disconnecting. The native viewer backend implements reconnect, the heartbeat watchdog and hidden-pane teardown; the standalone probe owns its own lifecycle.
- The package is split at the WebRTC seam (see the layout table above). `ScreenSharing` holds frames, the mailbox, metrics, the input/control/clipboard messages, the clipboard transfer, the `ScreenSharingMessageChannel` contract (one negotiated data channel today, an in-memory pair in tests), the `ScreenSharingViewingSession` contract a viewer renders from, and by stage folder `Capture/` (ScreenCaptureKit), `Codecs/` (VideoToolbox) and `Render/` (the Metal renderer, which draws biplanar YCbCr and packed BGRA frames). `ScreenSharingWebRTC` adds the `ScreenSharingSender` and `ScreenSharingReceiver` over a shared `ScreenSharingPeer` base, with their recovery objects and `ScreenSharingPeerOptions`; capture delivers into it through the `ScreenSharingFrameSink` protocol. The receiver is itself the `ScreenSharingViewingSession` a viewer renders from; `VNCScreenSharingSession` (`VNC/`) is the other implementation, over the `RFB/` protocol (see [the VNC viewer plan](../../../docs/plans/vnc-viewer.md)). Experiment-only instrumentation lives in `apps/screen-sharing-rig/Sources/ScreenSharingDiagnostics`. The viewer feature in `CodevisorCoreMac` is a Composable Architecture reducer over a `ScreenSharingViewerBackend` (the native backend owns signaling) with the control lease as a child reducer over a `ScreenSharingEndpointClient`; input events stay on the data plane inside the endpoint. See [the composable architecture plan](../../../docs/plans/screen-sharing-composable-architecture.md).
- The captured cursor is included in video. There is no cursor overlay, audio, automatic clipboard synchronization, virtual display, or saved screenshot. Native control and its separate lease are described above.

## Measurements and validation

The 30-minute baseline loopback completed at **57.83 presentation callbacks/second** (the original counter included skipped drawables; see the correction in the report), with no codec/render errors and a 293.52–298.88 MiB physical footprint after warm-up. See the [endurance report and raw timeline](../../../docs/measurements/native-screen-sharing-2026-09-10/README.md) for the workload, chart and limits. Adaptive-quality and recovery additions were checked in separate live probes.

The historical `presented fps` values in this section used that same callback counter and must not be interpreted as verified on-screen rates. The corrected probe records `unpresentedDrawables` separately.

Initial measurements on an Apple M4 Max, macOS 27.0 beta (26A428), debug build:

| Workload | Duration | Presented fps | Encode p95 | Decode p95 | GPU submission-to-completion p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Synthetic 1920×1080, requested 60 fps, same-process WebRTC loopback | 40.0 s | 59.1 | 6.78 ms | 1.11 ms | 0.72 ms |
| ScreenCaptureKit 1512×982 desktop, same-process WebRTC loopback | 10.0 s | 49.0 | 11.32 ms | 2.03 ms | 1.66 ms |

Viewer-initiated negotiation, matching the native tab, passed an eight-second synthetic 1080p check at 57.0 presented fps (encode p95 8.70 ms, decode p95 1.56 ms). The sender uses `addTrack` so a remote offer can associate it with the offered video m-line; an explicit unassociated transceiver had connected ICE without sending video. Loopback now exercises that negotiation direction.

The final callback/cleanup revision also passed a 10-second 1080p60 check at 56.2 presented fps (encode p95 8.24 ms, decode p95 1.45 ms). A 3840×2160 synthetic run at requested 60 fps / 24 Mbps passed at 45.2 presented fps, with encode p95 40.27 ms and decode p95 3.01 ms. That 4K run recorded 108 encoder admission drops: the encoder stage is the first bottleneck to investigate, and 4K60 has not been achieved.

These runs passed without codec errors. The synthetic run replaced 17 waiting renderer frames and had one encoder admission drop; VT reported four dropped frames during startup. SCK emits frames as content changes, and the desktop workload was not controlled. Builds were also running on the machine. These runs establish functionality, not a controlled performance comparison. Reports are kept locally under `tmp/screen-sharing/`.

Timing samples use a bounded rolling history of 1,800 observations. The fps calculation includes startup within the measured interval. GPU completion is measured separately from drawable presentation; neither is input-to-photon latency. The Simulator cannot report drawable presentation and only exposes GPU completion. No unrelated machine clocks are subtracted.

A separate sender/receiver process smoke test on this Mac passed the file-signaling flow, hardware codec path, and native rendering; both signaling files had mode `0600`. The native viewer was also inspected visually. The integrated development app successfully opened Screen Sharing from New Tab, enumerated the Retina display, and displayed live SCK video through the authenticated HTTP/Unix bridge. Switching away released the host immediately, returning renegotiated successfully, and explicit disconnect released it again. Actual Size rendered at one video pixel per backing pixel; a registry update to Fit resized the existing surface without reconnecting. Closing a connected tab released the host, and reopening restored the display and size preferences in the ready state. These are same-Mac functional checks, not two-Mac measurements. `--capabilities` reports advertised hardware H.264 and HEVC encode/decode on this M4 Max. The subsequent [tuftlord investigation](../../../docs/measurements/native-screen-sharing-tuftlord-2026-09-10/README.md) verifies hardware HEVC 4:4:4 round trips on M1 Pro and M4 Max, including 4K. The subsequent pipeline experiments add explicit HEVC/Main444 transport in the probe; product codec selection and performance promotion remain pending.

The control revision passed an eight-second synthetic 1080p loopback at 56.5 presented fps, including a bidirectional ordered data-channel check of eight input events and release while video ran. The probe’s input sink records these events without posting OS input. In the development app, missing Accessibility permission denied control; enabling it allowed explicit control, a physical key down/up crossed the native path exactly once, the local release shortcut worked, and switching tabs ended control. Returning resumed viewing without reacquiring control. In a split workspace, requesting control activated the viewer pane, and clicking the neighboring pane released input while video stayed visible. These checks do not establish two-Mac interaction fidelity or input-to-photon latency.

The clipboard/quality revision passed bidirectional large Unicode transfers on its independent data channel and all four live format transitions. After restoring 1080p60, the synthetic probe presented 59.8 fps over ten seconds; the SCK probe presented 56.3 fps. Both reported zero codec/render errors. The native-host API integration check also passed initial video, rejection of a different viewer without stopping video, replacement of the current peer, and rejection of renewal after host stop. No OS input or system clipboard changes were used by these probes.

Validation commands:

```sh
bun run swift:test
bun run --cwd apps/server test:coverage
bun run --cwd packages/automation test:coverage
swiftlint lint --strict --quiet packages/swift/ScreenSharing
bun run build:macos
bun run build:ios
```

Deterministic tests cover NAL framing and malformed input, configuration validation, newest-frame delivery, bounded metrics, pane metadata, synced preferences, control-message bounds, pointer geometry, fractional scroll accumulation, Quartz event construction, held-input release, late control grants, lease ownership/expiry, late signaling callbacks, hidden-tab cleanup and heartbeat failure. Focused HTTP and Unix-socket tests cover authenticated signaling, body limits, stale panes and socket cleanup. Neither permission prompts nor hardware/network benchmarks run in those tests. The full Swift package suite passes 1,788 tests. The server suite passes 449 tests and the automation suite passes 144 tests; both retain 100% measured coverage. Both existing native apps build, and the media module was separately typechecked against iOS device and Simulator SDKs. Device playback remains untested.

Milestone 0 now includes exploratory two-Mac runs and a matched-scale 4K recording comparison with Apple's High Performance mode. It remains open for isolated wired-LAN measurements, a matched 1080p Apple comparison, quantitative text fidelity and input-to-photon measurements, the controlled resource/latency comparison, and the dependency build/notice work below. Those are gates before claiming Apple-like performance or shipping the native pane.

## WebRTC dependency record

| Item | Pin |
| --- | --- |
| Swift package | `https://github.com/851-labs/webrtc.git`, exact `152.0.0-codevisor.1` (Codevisor's own source build; previously `stasel/WebRTC` `152.0.0`) |
| Package/reference commit | `c9d45927ea35ae3d83011f67fa1f06e61b5e5e2c` (stasel reference: `1d04692697cb642bfebf6ad2dd99fe52649c3d6d`) |
| Reported upstream WebRTC source commit | `6f37672d358475cd17544121a12494da454d85fb` (`branch-heads/7977`) |
| Binary | [WebRTC.xcframework.zip](https://github.com/851-labs/webrtc/releases/download/152.0.0-codevisor.1/WebRTC.xcframework.zip), with `manifest.json`, `revisions.txt`, GN arguments and generated notices attached to the release |
| SHA-256 | `85cfef48d8a6508af9c645a6887a13ec0ba38a71316195a1d0d9c9c3f051f013` (stasel 152.0.0: `115cb9944248a3302c0c8af17462e2576a28ccc7adef9f6a1fe66ee75d9e1cc8`) |
| Required slices present | macOS arm64/x86_64; iOS arm64; iOS Simulator arm64/x86_64 |
| Upstream workflow Xcode pin | `26.5` |
| Codevisor source-build Xcode pin | `27.0` (26.6 on September 14; 27.0 since September 15) |

SwiftPM validates the artifact checksum. The package and both Xcode workspaces pin the package revision. The reference checkout is [.repos/WebRTC](../../../.repos/WebRTC), added as a submodule. Since September 15 the installed dependency is Codevisor's own source build, published from the Xcode 27.0 recipe run described below; the stasel archive is retained as the reference the recipe was matched against.

The reference build script and release workflow are available at `.repos/WebRTC/scripts/build.sh` and `.repos/WebRTC/.github/workflows/webrtc-release.yml`. They build native Objective-C codec hooks and enable H.265 packetization. The distribution provides no Apple HEVC encoder/decoder implementation. Our custom VideoToolbox adapters provide H.264 by default and explicit HEVC/Main444 selection for probe experiments.

The Codevisor-owned recipe is [scripts/build-webrtc.mjs](../../../scripts/build-webrtc.mjs), with source, depot_tools, Python and Xcode pins in [webrtc-build.lock.json](../../../scripts/webrtc-build.lock.json). `node scripts/build-webrtc.mjs --plan` reviews its five architecture builds without changing files. The build disables depot_tools auto-update, explicitly bootstraps its pinned tools without advancing the checkout, records actual dependency revisions and GN arguments, generates notices from each platform's GN target graph, preserves dSYMs/privacy manifests, signs the local frameworks and writes an XCFramework archive with a SHA-256 manifest. Source and artifacts stay under a recipe-specific `tmp/webrtc-source/` directory; SwiftPM pins are unchanged.

A manual [artifact workflow](../../../.github/workflows/webrtc-artifact.yml) uploads a candidate for review without publishing it. Codevisor's recipe pins Xcode 27.0 as of September 15, 2026, after both development Macs moved to Xcode 27.0 (the App Store replaced 26.6 on the CI runner); the upstream workflow pins 26.5. The recipe was re-run on Xcode 27.0 (27A5237l) with Python 3.12.14 on September 15: all five architecture builds completed in about 17 minutes (recipe stamp `8ad07e67d25527ed`), candidate archive SHA-256 `85cfef48d8a6508af9c645a6887a13ec0ba38a71316195a1d0d9c9c3f051f013`, slices macos-arm64_x86_64, ios-arm64 and ios-arm64_x86_64-simulator with dSYMs, ad-hoc `org.webrtc.WebRTC` signatures, all 86 macOS public headers byte-identical to the published dependency, and generated macOS/iOS notices byte-identical to the audited notice files shipped in the module bundle. The unchanged media module compiled against the 27.0 candidate in an isolated package and all 181 tests passed. The archive was then published as `851-labs/webrtc` `152.0.0-codevisor.1` and installed as the package dependency in the Swift package and both Xcode workspaces; the media tests and the macOS and iOS builds pass against the installed dependency, the built macOS app embeds the exact candidate binary (matching LC_UUIDs), and the two-Mac rig streaming a 1920×1080@60 virtual display over the LAN with both ends on the new framework showed 52.4 presented / 55.5 decoded fps, zero encode/decode errors, 4.4 ms RTT and 100 ms p50 image age over 30 s, in line with the earlier stasel-build samples. Python remains pinned to 3.12.14. The complete source build passed on September 14 with Xcode 26.6 (17F113) and Python 3.12.14: macOS arm64/x86_64, iOS arm64 and Simulator arm64/x86_64. Candidate archive SHA-256: `cd477857489c347daddfbfa19bf0d905a2e2a143f3ee84543ba887b97cc13c45`. Graph-derived notices were checked against the exact source license texts across all five builds; the macOS notice has 25 sections and the iOS notice 23, including WebRTC. All 86 macOS public headers match the published dependency byte-for-byte. Architecture slices, privacy manifests, signatures and dSYM UUIDs passed inspection. The unchanged media module compiled against the candidate in an isolated package, all 180 tests passed, and a native factory/source/track/peer/data-channel creation-and-close smoke passed without capture or connection. This is one successful build, not proof of byte reproducibility or a media/performance comparison. That 26.6 candidate was never installed; the 27.0 build replaced the stasel artifact as the installed dependency on September 15. Performance equivalence against the stasel build has not been measured.

The archive's WebRTC BSD notice is copied into the module resource bundle and the diagnostic app. The framework's supplied privacy manifest is preserved. The published archive does not include an aggregate third-party license file. The exact audited macOS and iOS notice files now ship in `CodevisorKit_ScreenSharingWebRTC.bundle` through explicit SwiftPM copy resources, alongside the main WebRTC license. The probe copies that same resource bundle. The notices are generated from the pinned source and matching upstream build arguments; the product continues using the checksum-verified published binary. The existing macOS release script already signs and verifies embedded frameworks inside-out, including WebRTC. A signed/notarized release containing this feature has not been produced or published.

Notice provenance (generated text is preserved byte-for-byte):

| Resource | SHA-256 |
| --- | --- |
| `WebRTC-ThirdPartyNotices-macOS.md` | `b31e3534049987e366e146ed4197bd63feb87d99b7a456e1290ce7172b7662df` |
| `WebRTC-ThirdPartyNotices-iOS.md` | `c14b7a9740d38cf418f56d2189e1cf266e61b887166e89a570f7a8bef02c488e` |

Regenerate with `node scripts/build-webrtc.mjs`; audit `artifacts/notices-macos/LICENSE.md` and `artifacts/notices-ios/LICENSE.md` against the recorded target graphs before copying them to `Sources/ScreenSharingWebRTC/Resources/`. The main WebRTC source revision, dependency revisions, GN arguments and build tools are recorded in the recipe output. These notices cover the native macOS and iOS configurations; Mac Catalyst is not a Codevisor target.

Control API references: [WebRTC data channels](https://webrtc.org/getting-started/data-channels), [Apple’s private event-source state](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid), and [event-source user data](https://developer.apple.com/documentation/coregraphics/cgeventsource/userdata). Native channel signatures were checked against the pinned M152 framework headers.


`--check-recovery --keyframe-interval 60 --duration 15` performs a local loopback recovery check. After 120 decoder inputs, a package-only diagnostic hook destroys the VideoToolbox decoder state and rejects deltas until a fresh keyframe arrives. The check requires one reset, a replacement keyframe within two seconds and subsequent decoded/presented frames. A sixty-second nominal periodic interval prevents an ordinary scheduled keyframe from satisfying this short check. This is fault injection at the decoder, not a packet-loss emulator or a physical latency measurement. It cannot be combined with quality transitions or nonmedia checks.

Transport keyframe requests remain pending through bounded-pool admission drops and VideoToolbox completion. Only usable keyframe output delivered to the encoder callback fulfills a request. One forced attempt is allowed in flight; dropped, failed or unusable output retries on a later input frame. Request generations prevent an older keyframe from clearing a newer request, and attempt identifiers reject stale completions. Local H.264 and HEVC Main444 checks recovered in 22.78 and 17.96 ms; a separate 4K Main444 check with one admitted frame recovered in 18.68 ms. These runs validate the recovery path but do not establish loss resilience on a real congested network, or constitute a hardware fault-injection test of VideoToolbox dropping a submitted keyframe. Six deterministic request-state tests cover that retry decision and completion ordering. See the [recovery results](../../../docs/measurements/native-screen-sharing-pipeline-2026-09-11/recovery-checks.json).


`--capture-picker-window` authorizes one window through macOS's native content picker. For capture isolation, `--show-workload --workload-window` creates a borderless window whose backing pixels match the requested raster, including portions outside a smaller physical display. The workload writes `<report>.ready.json` with its window ID, actual point size and backing scale. SCK metrics independently record the selected content size/scale. This diagnostic supports comparing real 4K window capture without a competing Apple stream; it is explicitly distinct from full-display capture. The app's display chooser is unchanged.

### Display-link cadence diagnostic

The standalone probe accepts `--render-fps N` (30...240) to request a Metal display-link cadence independently of the stream FPS. It excludes `--render-on-arrival` and requires a viewer or loopback. This allows a fixed 60 fps stream to be measured on, for example, a verified 72 Hz display without changing application renderer defaults. The report labels `renderRequestedFPS`; actual scheduling must be checked through `renderDriveInterval` and native presentation counters. The fresh [separate-stream Apple comparison](../../../docs/measurements/native-screen-sharing-independent-2026-09-11/README.md) records the current candidate and the remaining smoothness/latency limits.

`--metal-display-link` selects a separate probe-only `CAMetalDisplayLink` driver. It uses the drawable supplied by each update, requests preferred frame latency 1 and the selected render cadence, and records callback intervals and target presentation lead. It requires a receiver or loopback and excludes frame-arrival rendering. Apple's requested latency is best effort, and the local control still measured approximately 50 ms from submission to presentation. The normal app continues using MTKView scheduling; this experiment makes no claim about Apple's Screen Sharing internals.

### Calibrated image-age diagnostic

`--show-workload --record-workload-times` records the first monotonic AppKit draw-start timestamp for each visible marker code. It limits workload duration to 240 seconds and retains at most 20,000 entries. `--clock-sync` runs alone as a bounded stdin/stdout timestamp responder for request-bracketed clock-offset calibration; it does not adjust system clocks.

`--observe-window --window-id ID --content-top-points N --duration 30 --report /path.json` uses existing Screen Recording permission to sample one known viewer window. Omitting `--window-id` uses the system sharing picker. It retains numeric marker codes and local SCK sample/callback timestamps, with no recording, pixel retention, audio or input injection. Source raster defaults to 3840×2160; capture preserves aspect ratio up to 1920 pixels wide. A before/after clock calibration and the workload draw report are required to calculate cross-Mac image age. The [analysis and local control](../../../docs/measurements/native-screen-sharing-independent-2026-09-11/image-age/README.md) document the first Codevisor/Apple comparison and its uncertainty. This metric is not physical presentation or input-to-photon latency.

Add `--capture-kind display-crop` to sample the display region containing that window instead of an independent window surface. It requires a window ID, existing capture permission, and the whole window visible on one attached display. Readiness and final reports include the display ID and crop rectangle in display-local points. It preserves ordinary occlusion; moving or covering the marker can invalidate the observation. Independent-window and display-crop samples are distinct measurement modes and must not be mixed in a parity claim. The known workload marker requires a source width of at least 900 pixels because its response panel overlaps the marker below that width.

`--viewer-display ID` places the probe viewer on an explicitly verified, attached local display. It requires a viewer or loopback. Viewer runs write `<report>.viewer-ready.json` with the actual window/display ID, content size, chrome inset and backing scale, so observation can target the correct window without changing focus. A Release loopback check verified placement on display 2 at 960×540 content points and 2× backing scale; invalid IDs and incompatible modes were rejected. Display IDs are local, transient diagnostics and are not persisted as product preferences.

`--low-latency-playout` is a separate receiver/loopback experiment. Before any RTC initialization, the standalone process sets the pinned M152 `WebRTC-ForcePlayoutDelay` trial to `min_ms:0,max_ms:0`. The upstream receiver accepts these values and the timing implementation selects rendering as soon as possible. This is a request to remove playout waiting, not a guarantee of zero latency or a bound on network delay; it may expose more stuttering under variable delivery. It retains encryption, codec recovery and transport feedback. Application initialization and defaults are unchanged.

The trial was verified in the pinned [receiver parser](https://webrtc.googlesource.com/src/+/6f37672d358475cd17544121a12494da454d85fb/video/rtp_video_stream_receiver2.cc) and [timing implementation](https://webrtc.googlesource.com/src/+/6f37672d358475cd17544121a12494da454d85fb/modules/video_coding/timing/timing.cc); its identifier is present in the downloaded M152 binary. A ten-second local H.264 recovery check passed with a 0.18 ms cumulative receive-buffer mean and recovery in 16.45 ms after injected reference loss. Those local results are functional evidence, not a remote performance result. Probe media reports now include their monotonic measurement start and write `<report>.media-ready.json` so later observations can be aligned with transport timelines.

`--check-recovery --headless-recovery --keyframe-interval 60 --duration 10` runs real local WebRTC and hardware codec recovery without a window or capture. Its report sets `renderingEnabled: false`, labels presentation telemetry disabled, and requires decoded recovery instead of rendered frames. It rejects viewer/capture options and cannot establish presentation performance. The updated encoder passed local H.264 recovery in 16.13 ms and 4K Main444 recovery in 28.01 ms; [saved reports](../../../docs/measurements/native-screen-sharing-independent-2026-09-11/recovery/README.md) retain the counters and limits.

Add `--drop-recovery-keyframe` to deliberately discard the next forced encoder output after the decoder reset. The request must survive that loss: the probe requires one injected drop, a retry, at least three forced submissions (initial keyframe, discarded recovery attempt, replacement), and successful decoder recovery. Local H.264 and 4K Main444 checks passed with two requests, three submissions and one retry, recovering in 32.39 and 61.94 ms. The fault discards real VT output at the application callback; it does not induce an internal codec failure or emulate network packet loss. It is unarmed in the application.

### Idle delivery audit

Trailing packet loss before the desktop goes idle produces no decoder error, no later sequence gap and, in the pinned M152 sources, the same single PLI that a healthy idle transition produces. Every encoded frame therefore carries its content identity, the capture timestamp, in a zero-byte-free user-data SEI NAL unit (30 bytes for H.264, 31 for HEVC). The identity is attached to the pixel buffer by `ScreenSharingFrameSender`, because WebRTC's native source truncates and translates the submitted timestamp before the encoder sees it; the transport encoder refuses input without it through the `encoderError` lifecycle, and the decoder reads and strips the marker before VideoToolbox.

After 100 ms without a capture submission the host re-offers a latest capture that was never encoded (four times at the threshold, then every 2 s until it is encoded, replaced or the peer closes) and then sends one `sourceIdle` notice over the video-refresh channel. The viewer compares the announced identity with its newest decoded one; if older it waits a 100 ms grace, extended by up to four more windows while strictly newer content keeps arriving (at most 500 ms after the notice), then requests a keyframe through the recovery path, keeps the target until that content is decoded, and retries stale completions with a 100 ms to 5 s backoff. These defaults were promoted after the [brief-loss measurements](../../../docs/measurements/native-screen-sharing-independent-2026-09-11/brief-loss/README.md); the former 500 ms threshold and fixed 500 ms grace remain explicit probe overrides. Healthy idle costs one wake per 100 ms of activity, one nine-byte message per idle transition and no encode. [Measured results](../../../docs/measurements/native-screen-sharing-independent-2026-09-11/network-loss/README.md) cover a local encrypted UDP relay with a five-second video blackout, plus the decoder-reset and idle checks on both Macs; the [brief-loss report](../../../docs/measurements/native-screen-sharing-independent-2026-09-11/brief-loss/README.md) covers brief trailing loss, healthy delayed streams and the promotion of the current defaults.


The receiver also requests a refresh over the bounded negotiated `codevisor.video-refresh.v1` SCTP stream (ID 4) before its first decoded keyframe and after decoder failure. Both endpoints rate-limit refreshes to at most ten per second. The sender retains at most one capture buffer and resubmits it with a strictly increasing host-clock timestamp, forcing a keyframe, so an idle desktop can recover without new ScreenCaptureKit output. Pending recovery retries stop after a successfully decoded keyframe; normal idle screens have no refresh timer. Decoder generations reject stale completions, and VT callback errors schedule session reset on the decoder queue. Close and format changes release the cached buffer. This adds one retained capture surface; sustained capture-pool and network-loss checks remain necessary.

`--idle-on-decoder-reset` requires headless recovery and suspends fresh capture forwarding exactly at the reset edge, while leaving the last frame available for explicit refresh. It can combine with `--drop-recovery-keyframe`. The probe requires decoded recovery and an unchanged capture/encode/request count after a two-second settling checkpoint. `--pause-source-after N` instead stops the synthetic source at a specified time, with at least three active and three remaining seconds; it excludes idle-at-reset. These checks use hardware media with synthetic input and do not measure visible presentation or Apple parity.

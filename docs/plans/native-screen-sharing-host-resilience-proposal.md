# Proposal: host capture resilience and sleep policy

Status: proposal, 2026-09-15, from findings made with the Screen Sharing rig ([docs/plans/screen-sharing-rig.md](screen-sharing-rig.md)). No product code changes here; each item goes through the normal review.

## Findings that affect the product host today

1. **Display sleep stops every ScreenCaptureKit stream and none resumes on wake.** On the rig, `pmset displaysleepnow` on the host ended the stream within a second with "Failed to find any displays or windows to capture"; the WebRTC session stayed connected at 0 fps indefinitely. The product host currently ends the session on `screensDidSleep` and related system events (`ScreenSharingHostService.systemStopped`), so a viewer sees a stop and must reconnect after wake; with the host's idle display sleep at its default, an unattended host stops serving after a few minutes without input.
2. **`replayd` exhaustion is silent.** The capture daemon leaks about two pipe descriptors per ScreenCaptureKit stream. At its file limit a new stream starts, delivers no frames and reports no error, for physical and virtual displays alike. Recovery requires `kill -KILL` of the user's `replayd` (launchd respawns it); `launchctl` is refused under SIP and SIGTERM is ignored. The September 11 measurements hit the same condition.
3. **Granting a TCC permission to a running app makes macOS quit and reopen it.** A host that exits cleanly during that step must come back on its own; the rig's LaunchAgent restarts the host on any exit for this reason.
4. **A virtual display costs 2–3 fps of capture cadence and nothing in fidelity** against owned-window capture of the same content (both 1:1). Its value is independence from the physical desktop and, potentially, headless hosts — which is still untested on a Mac with no display attached.

## Proposed product changes

- **Hold `PreventUserIdleDisplaySleep` while a session is live** (`IOPMAssertionCreateWithName`), released when the session ends. Apple's Screen Sharing behaves this way. An explicit `displaysleepnow`, lid close or lock still stops the displays; the assertion only removes idle sleep as a cause of a silent host.
- **Restart capture on a stream error instead of ending the session**, bounded (for example every 5 s), and end the session only after a bounded number of failures. The rig measured recovery within a second of wake with this policy, on the same WebRTC session, with no viewer action. This also covers display reconfiguration where the selected display survives.
- **Treat "started, no frames" as a distinct state.** After a capture starts, no delivered frame within a few seconds should set a visible host state ("capture stalled") and log it, rather than showing a connected session at 0 fps. The rig's `sourceStall` label is the shape.
- **Do not add a virtual-display source to the MVP.** If headless hosts become a goal, add it behind an explicit setting with a visible fallback to the physical display; the private-API dependency (`CGVirtualDisplay`) is acceptable in the rig and needs a product decision before it enters the app. The decisive experiment — creation on a Mac with no display at all — needs a Mac mini or similar and is cheap with the rig.

## What this does not claim

No latency or parity result; no change to codec, transport or renderer defaults; no statement about relay paths. The sleep and stall behaviours were measured on the rig's host, which shares the capture and WebRTC code with the product but not the product's session lifecycle.

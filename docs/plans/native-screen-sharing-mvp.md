# Native Screen Sharing MVP checkpoint

This is an implementation review checkpoint for a macOS LAN beta. It is not a performance-parity or release-acceptance report.

The intended MVP is one Codevisor Mac viewing and controlling an existing display on another Codevisor Mac. The host runs the native app in its logged-in session with Screen Recording permission; control additionally requires Accessibility permission on the host. Capturing system keyboard shortcuts also requires Accessibility permission on the viewer. One viewer owns the host at a time.

## Implemented

- ScreenCaptureKit capture, VideoToolbox H.264 encode/decode, encrypted WebRTC media and Metal rendering.
- Authenticated workspace/pane signaling and a searchable display chooser matching New Tab.
- Native toolbar with the machine name and display resolution, a persistent View/Control segment, Fit/Actual Size, clipboard and connection diagnostics. Closing the tab ends the session.
- Control is requested once when each connection becomes ready. Local menus and other focused controls suspend input forwarding and release held input without changing the selected mode. Ctrl-Option-Escape releases control explicitly.
- While the video has focus in Control mode, system shortcuts such as Command-Space and Command-Q are forwarded to the host; bounded plain-text clipboard transfer is also available.
- Chatless workspace navigation through the shared pane container, including conversion from New Tab and sidebar title updates.
- Bounded media ownership, terminal renderer stop and owner-scoped cancellation of pending host starts.
- A default-off `CODEVISOR_SCREEN_SHARING_DIAGNOSTIC_PROFILE=paced15-worker` profile: 120 fps capture request at adaptive level zero, 1–15 ms receiver playout bounds, synchronized arrival rendering with two drawables and off-main preparation. A capture request is not an achieved frame rate. Process-wide WebRTC configuration requires an app restart to change.
- A standalone probe and a pinned WebRTC artifact-build recipe. The recipe's complete source build and generated dependency notices remain unverified.

## Existing verification

Actual-app checks on September 14 established remote video and control, including opening Spotlight, typing, and quitting the remote Calculator with Command-Q while the local viewer stayed connected. These checks used the pre-integration development build. A clean two-Mac acceptance run on the integrated source remains required; these checks are not a performance benchmark.

The final host stop-ordering source passed 167 CoreMac tests and serial macOS/iOS native builds on September 13, 2026. The sidebar and host-ordering fixes were compiled in isolated build outputs but have not yet been exercised in a newly launched two-Mac session. These are historical results, not acceptance evidence for the integrated branch. The September 14 integration adopts main's center-only workspace layout and focus-source ownership, and preserves chatless workspace behavior. Current build and full-check results are recorded in the PR.

The local measurement archives contain raw session and machine-specific evidence and are intentionally excluded from this public checkpoint. Historical measurement links in the implementation notes refer to those local archives. No credentials, raw signaling, desktop captures or runner logs are required to build the feature.

## Before MVP acceptance

1. Verify the final source in two actual apps: permissions, viewing, typing, clicking, dragging, scrolling, clipboard, scaling and display selection.
2. Verify input release and capture cleanup on focus loss, pane hide/close, disconnect, host stop and reconnect; verify no stale start revives a stopped session.
3. Complete a visible sustained-use check for responsiveness, resources and bounded queues using the configuration intended for users.
4. Review the pinned dependency, distributed notices, signing/packaging and clean CI results. Any revision to the source-build prerequisite in the original plan must be explicit.
5. Review the integrated shared workspace-navigation changes for regressions, including chatless workspaces, tab selection and focus ownership.

Apple parity, a production-default tuning change, iOS viewing, audio, virtual displays, multiple viewers and internet/forced-relay guarantees are outside this MVP checkpoint. Existing connectivity code does not establish those guarantees.

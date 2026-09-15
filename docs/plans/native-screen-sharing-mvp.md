# Native Screen Sharing MVP checkpoint

This is an implementation review checkpoint for a macOS LAN beta. It is not a performance-parity or release-acceptance report.

The intended MVP is one Codevisor Mac viewing and controlling an existing display on another Codevisor Mac. The host runs the native app in its logged-in session with Screen Recording permission; control additionally requires Accessibility permission on the host. Capturing system keyboard shortcuts also requires Accessibility permission on the viewer. One viewer owns the host at a time.

## Implemented

- ScreenCaptureKit capture, VideoToolbox H.264 encode/decode, encrypted WebRTC media and Metal rendering.
- Authenticated workspace/pane signaling and a searchable display chooser matching New Tab.
- Native toolbar with the machine name and display resolution, a persistent View/Control segment, Fit/Actual Size, clipboard and connection diagnostics. Closing the tab ends the session.
- New panes start in Control mode. The View/Control selector remains interactive while connecting, and the latest choice applies when video and the control channel are ready. Reconnecting preserves that choice. Local menus and other focused controls suspend input forwarding and release held input without changing the selected mode. Ctrl-Option-Escape releases control explicitly.
- While the video has focus in Control mode, system shortcuts such as Command-Space and Command-Q are forwarded to the host; bounded plain-text clipboard transfer is also available.
- Chatless workspace navigation through the shared pane container, including conversion from New Tab and sidebar title updates.
- Bounded media ownership, terminal renderer stop and owner-scoped cancellation of pending host starts.
- A default-off `CODEVISOR_SCREEN_SHARING_DIAGNOSTIC_PROFILE=paced15-worker` profile: 120 fps capture request at adaptive level zero, 1–15 ms receiver playout bounds, synchronized arrival rendering with two drawables and off-main preparation. A capture request is not an achieved frame rate. Process-wide WebRTC configuration requires an app restart to change.
- A standalone probe and a pinned WebRTC artifact-build recipe. The recipe's complete source build and generated dependency notices remain unverified.

## Existing verification

Actual-app checks on September 14 established remote video and control, including opening Spotlight, typing, and quitting the remote Calculator with Command-Q while the local viewer stayed connected. These checks used the pre-integration development build. A clean two-Mac acceptance run on the integrated source remains required; these checks are not a performance benchmark.

Commit `dbdbcaea` passed the normal pre-commit hook in a clean validation worktree, without exclusions: the full JavaScript check chain, Swift formatting/lint, 2,119 Swift package tests, 30 macOS transcript tests, 11 macOS composer tests, the iOS build, and 8 iOS transcript tests. The macOS development app built successfully. The September 14 integration adopts main's center-only workspace layout and focus-source ownership, and preserves chatless workspace behavior.

Actual-app checks with the final viewer established that the complete toolbar stays interactive during connection, View/Control choices survive connection and menu interactions, and switching modes no longer shows a spinner. Those checks used the earlier host build. The isolated host was subsequently rebuilt from the matching final source; all 2,864 staged source files were verified and the app passed strict signature verification. The fresh acceptance attempt reached the host Screen Recording permission error. The remaining two-Mac workflows and sustained-use check are pending reauthorization of this rebuilt development app; earlier results do not replace that acceptance pass.

The local measurement archives contain raw session and machine-specific evidence and are intentionally excluded from this public checkpoint. Historical measurement links in the implementation notes refer to those local archives. No credentials, raw signaling, desktop captures or runner logs are required to build the feature.

## Dependency and distribution review

The pinned stasel WebRTC 152.0.0 archive was downloaded again on September 14. Its SHA256 matches `scripts/webrtc-build.lock.json` and the SwiftPM checksum: `115cb9944248a3302c0c8af17462e2576a28ccc7adef9f6a1fe66ee75d9e1cc8`. All 387 regular files and 10 symlink targets match the resolved artifact. The XCFramework provides macOS arm64/x86_64, iOS device and simulator slices, and Mac Catalyst slices.

The built macOS app includes the WebRTC license and privacy manifest. The app and its embedded WebRTC framework pass strict signature verification. The release script signs embedded frameworks before signing and verifying the enclosing app; Developer ID signing and notarization of this final revision have not been executed.

The archive contains the main WebRTC license but no aggregate third-party notices. The pinned source build and graph-derived notice audit remain open. On September 14, the Xcode pin was deliberately updated from 26.5 to the available 26.6 toolchain; Python remains pinned to 3.12.14. The earlier 26.5 refusal was the recipe's exact-version check, not an established upstream compatibility limit. The WebRTC source revision and installed dependency remain unchanged; the candidate artifact must pass its build, notice audit and validation before promotion.

Pushing to `main` automatically starts the Alpha build and publication workflow, so the dependency/distribution gate cannot be deferred to a later manual release. The PR currently has no completed GitHub build/test workflow; its correctness check is skipped while in draft. The full-check result above is local verification, not a CI result.

## Before MVP acceptance

1. Verify the final source in two actual apps: permissions, viewing, typing, clicking, dragging, scrolling, clipboard, scaling and display selection.
2. Verify input release and capture cleanup on focus loss, pane hide/close, disconnect, host stop and reconnect; verify no stale start revives a stopped session.
3. Complete a visible sustained-use check for responsiveness, resources and bounded queues using the configuration intended for users.
4. Review the pinned dependency, distributed notices, signing/packaging and clean CI results. Any revision to the source-build prerequisite in the original plan must be explicit.
5. Review the integrated shared workspace-navigation changes for regressions, including chatless workspaces, tab selection and focus ownership.

Apple parity, a production-default tuning change, iOS viewing, audio, virtual displays, multiple viewers and internet/forced-relay guarantees are outside this MVP checkpoint. Existing connectivity code does not establish those guarantees.

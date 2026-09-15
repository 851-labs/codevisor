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
- A standalone probe and a pinned WebRTC artifact-build recipe. The source build, generated-notice audit and isolated candidate tests now pass with Xcode 26.6; the candidate is not installed or promoted.

## Existing verification

Actual-app checks on September 14 established remote video and control, including opening Spotlight, typing, and quitting the remote Calculator with Command-Q while the local viewer stayed connected. These checks used the pre-integration development build. A clean two-Mac acceptance run on the integrated source remains required; these checks are not a performance benchmark.

Commit `dbdbcaea` passed the normal pre-commit hook in a clean validation worktree, without exclusions: the full JavaScript check chain, Swift formatting/lint, 2,119 Swift package tests, 30 macOS transcript tests, 11 macOS composer tests, the iOS build, and 8 iOS transcript tests. The macOS development app built successfully. The September 14 integration adopts main's center-only workspace layout and focus-source ownership, and preserves chatless workspace behavior.

Main integration `166fce13` brings in `10bdc699`'s attachment-thumbnail framing fix without conflicts. That merge, notice/CI commit `acd462f8`, and CI tooling correction `d627587d` each passed the complete normal pre-commit hook without exclusions. The combined macOS build passed, and the resource bundle's two dependency-notice files match the audited source hashes.

Actual-app checks with the final viewer established that the complete toolbar stays interactive during connection, View/Control choices survive connection and menu interactions, and switching modes no longer shows a spinner. Those checks used the earlier host build. The isolated host was subsequently rebuilt from the matching final source; all 2,864 staged source files were verified and the app passed strict signature verification. The fresh acceptance attempt reached the host Screen Recording permission error. The remaining two-Mac workflows and sustained-use check are pending reauthorization of this rebuilt development app; earlier results do not replace that acceptance pass.

The local measurement archives contain raw session and machine-specific evidence and are intentionally excluded from this public checkpoint. Historical measurement links in the implementation notes refer to those local archives. No credentials, raw signaling, desktop captures or runner logs are required to build the feature.

## Dependency and distribution review

The pinned stasel WebRTC 152.0.0 archive was downloaded again on September 14. Its SHA256 matches `scripts/webrtc-build.lock.json` and the SwiftPM checksum: `115cb9944248a3302c0c8af17462e2576a28ccc7adef9f6a1fe66ee75d9e1cc8`. All 387 regular files and 10 symlink targets match the resolved artifact. The XCFramework provides macOS arm64/x86_64, iOS device and simulator slices, and Mac Catalyst slices.

The product now bundles the main WebRTC license, audited macOS/iOS third-party notices and the framework's privacy manifest. The notices are explicit SwiftPM copy resources, with provenance and hashes in the [library README](../../packages/swift/CodevisorScreenSharing/README.md). The installed binary dependency is unchanged.

The published archive contains the main WebRTC license but no aggregate third-party notices. On September 14, the Xcode pin was deliberately updated from 26.5 to 26.6 (17F113), with Python 3.12.14 unchanged. The first source-build attempt found a missing depot_tools bootstrap before GN; the corrected recipe initializes the pinned tools without updating their revision. The subsequent complete build passed for all five macOS/iOS architectures and packaged a candidate XCFramework (`cd477857489c347daddfbfa19bf0d905a2e2a143f3ee84543ba887b97cc13c45`). The generated notices match the exact source license texts for every mapped dependency in all five target graphs. Headers, slices, signatures, privacy manifests and matching dSYM UUIDs passed inspection; all 180 unchanged screen-sharing tests passed against the isolated candidate, as did factory/track/peer/data-channel creation and close. No capture or media connection was run with it.

An unpublished Developer ID packaging run of `acd462f8` completed through the ordinary release script with version `0.0.0`. Both architecture-specific ZIPs and DMGs passed verification. The apps and embedded WebRTC framework have Developer ID signatures, hardened runtime and secure timestamps; both ZIPs preserve the exact audited notice bytes and privacy manifest, and both DMG checksums/signatures passed. The signed ARM runtime loaded the screen-sharing API and exercised an in-memory SQLite database. No app UI or media session was launched by this verification.

This was a local packaging check using the installed Xcode 27 beta; the hosted native PR check is pinned to Xcode 26.6. The ARM runtime was rebuilt from this revision. For Intel, only the unchanged native Node/dependency tree was reused from main's successful CI run at `10bdc699`, with current JavaScript and resources. All dependency manifests and the lockfile matched (the root manifest differs only by the development probe script); 2,019 current non-native files and all eight Intel Mach-O files were checked. Intel execution was unavailable without Rosetta. These review artifacts were not published and do not replace native release builds. Notarization was not attempted because this session has no notarization credentials.

The source-built WebRTC candidate remains isolated and unpromoted; actual-app validation is required before replacing the installed dependency. A successful source build does not establish byte reproducibility or performance equivalence.

Pushing to `main` automatically starts the Alpha build and publication workflow, so final CI, distribution and actual-app acceptance must be reviewed before merging. [PR #7](https://github.com/851-labs/codevisor/pull/7) is now ready for review, with non-publishing GitHub-hosted JavaScript and native checks. Native validation uses Xcode 26.6 and checksum-pinned SwiftLint 0.63.1; the first hosted run exposed the missing linter, which was corrected. Check the final head's live results on the PR rather than treating local hooks as CI. A hosted run also exposed a timeout in the existing MP4 integration test. Its fixture now awaits SDK callbacks asynchronously, propagates startup errors and cancels the writer during cleanup; it retains all MP4 duration/dimension/final-frame assertions. This removes blocking bridge-worker waits from an async test but does not by itself establish the hosted failure's cause. The package-test step has a 15-minute deadlock bound. Macroscope's automatic review is unavailable because of a workspace billing/usage issue; no automatic review approval is claimed. The PR has not been merged.

A local single-worker reproduction subsequently identified two independent test scheduling defects: preparation fixtures blocked Swift workers with semaphores while waiting for other Swift tasks, and cloud fixtures retried closed sockets with zero virtual delay. Preparation seams now allow asynchronous test gates; cloud fixtures suspend on a positive virtual backoff that reconnect tests advance explicitly. Production parsing, latest-value selection and reconnect policy are unchanged. The full package suite completes with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`; this reproducer result is separate from the final hosted CI verdict.

## Before MVP acceptance

1. Verify the final source in two actual apps: permissions, viewing, typing, clicking, dragging, scrolling, clipboard, scaling and display selection.
2. Verify input release and capture cleanup on focus loss, pane hide/close, disconnect, host stop and reconnect; verify no stale start revives a stopped session.
3. Complete a visible sustained-use check for responsiveness, resources and bounded queues using the configuration intended for users.
4. Review the pinned dependency, distributed notices, signing/packaging and clean CI results. Any revision to the source-build prerequisite in the original plan must be explicit.
5. Review the integrated shared workspace-navigation changes for regressions, including chatless workspaces, tab selection and focus ownership.

Apple parity, a production-default tuning change, iOS viewing, audio, virtual displays, multiple viewers and internet/forced-relay guarantees are outside this MVP checkpoint. Existing connectivity code does not establish those guarantees.

# Codevisor iOS App — Phased Plan

Goal: a native iOS Codevisor client with full feature parity with the macOS app,
built by **sharing code, not porting it**. iOS is a pure client — it never runs a
local server; it pairs with remote machines (including the Mac dev instance).

Guiding principles:

- **Share the brain, adapt the shell.** Everything below the view layer
  (protocol, transport, view models, transcript reduction, persistence,
  theming, highlighting) is shared verbatim. Views are shared where SwiftUI is
  platform-neutral; only the thin platform leaves (scrolling, text editing,
  images, pasteboard) fork.
- **iOS-native, not macOS-crammed.** NavigationStack, sheets, context menus,
  keyboard avoidance, Liquid Glass materials, HIG spacing/typography. The app
  should feel like the iOS expression of Codevisor.
- **Never break macOS.** Every phase is a sequence of pure moves and additive
  changes. `bun run check` (including `swift:test`) must pass unchanged after
  every phase; macOS behavior changes are out of scope.
- **Both-platform development.** After Phase 2, a feature built in the shared
  packages lights up on both apps; CI builds both so a regression on either
  platform blocks merge.

Status note: scaffolding is already done — `apps/ios/Codevisor.xcodeproj`
(bundle id `com.dylanplayer.codevisor.ios`, temp until the Codevisor LLC
developer account exists), shared package linkage proven (ACPKit +
CodevisorTheming), `bun run dev:ios` starts the Dev Remote server and boots the
app in the simulator, and the Xcode MCP tooling loop (build/run/tap/logs) is
verified.

Progress:

- **Phase 1: done.** `CodevisorCoreMac` target holds the local server /
  computer use / Process code behind the `LocalServerControlling` seam;
  `CodevisorCore` builds and links on iOS; `swift:build:ios` is part of
  `bun run check`.
- **Phase 2: mostly done.** `SessionController` (publicized) lives in
  `CodevisorCore` with an injected `ChatNotificationDelivering` seam;
  `CodevisorUI` holds `Theme` (platform-forked system colors), `Motion`, the
  markdown/highlight adapters, transcript environment keys, the transcript row
  views (`ToolCallRow`, `ToolGroupView`, `DiffView`, `PlanDocumentView`,
  `TodoPanelView`, `GoalBannerView`, `MessageCopyButton`, disclosure chrome)
  and their design-system foundations; `PlatformShims` provides
  `OSColor`/`OSFont`/`OSImage`/`PlatformPasteboard`. `StreamMarkdown` compiles
  for iOS (AppKit view layer gated; interim pure-SwiftUI renderers).
  Remaining: UIKit/TextKit 2 counterparts for the StreamMarkdown views;
  `AssistantTurnView`/`TranscriptItemsView`/attachment stack migration; the
  pane-factory seam that would unstrand `SessionStore`/`PaneGroupModel`
  (deferred to Phase 6).
- **Phase 3: mostly done.** Machine picker, manual pairing (validated),
  `codevisor://` deeplink handling, dev auto-pair from the launch environment,
  the touch-native home screen (Agents/Projects grouping, status accents,
  live event sync, pull-to-refresh), and worktree dev parity (per-worktree
  bundle id, display name, and hash-colored springboard icon matching the
  macOS derivation). Remaining: QR scanning, richer filters, settings v1,
  Keychain token storage.
- **Phase 4: read path shipped.** `SessionScreen` renders real transcripts
  through the shared engine (verified against a live claude-code run on the
  dev remote). Remaining: the `VirtualTranscriptLayout`-backed virtualizer,
  worked-section collapsing, attachments/lightbox.
- **Phase 5: core loop shipped.** Bottom-docked keyboard-riding composer with
  shared send/stop/draft handling; verified prompt round-trip from the phone.
  Remaining: attachments, model/mode pickers, question picker cards, the
  swipe-up expanded editor, usage ring, new-chat flow.

---

## Phase 1 — Platform-neutral core (no UI, no behavior change)

Make `CodevisorCore` compile and test on iOS. This is the keystone; everything
else depends on it, and it hardens the client/server-lifecycle boundary for the
macOS app too.

Work items:

1. New `CodevisorCoreMac` target in `apps/macos/Packages` (macOS-only),
   depending on `CodevisorCore`. Move the platform-bound files there:
   - `Server/LocalCodevisorServer.swift`, `Server/CommandRunner.swift`,
     `Server/EnvironmentProbe.swift`, `Server/TailscaleDiscovery.swift`
     (all use `Process`)
   - `Server/ComputerUseBridge.swift`, `ComputerUsePresentation.swift`,
     `ComputerUseNativeSharing.swift` (ScreenCaptureKit/AX/CGEvent)
   - The `Process` usage in `Analytics/AnalyticsClient.swift` (split the
     macOS-only probe out; keep the PostHog client shared)
2. Neutralize small leaks inside `CodevisorCore`:
   - `Theme/ThemeManager.swift`: extract the `NSApp.appearance` call behind an
     injected `PlatformAppearanceApplier` (macOS impl in `CodevisorCoreMac`,
     iOS impl in the app).
   - `Persistence/PersistenceStore.swift`: replace the hardcoded
     `"NSApplicationWillTerminateNotification"` with a platform-conditional
     notification name (`UIApplication.willTerminateNotification` +
     `willResignActiveNotification` on iOS — iOS apps are killed without
     terminate callbacks, so flush on background too).
   - `AppEnvironment`: split `live()` so the shared graph builds without the
     macOS-only pieces (`localServer`, computer use, update model become
     injections supplied by each app).
3. Move the corresponding tests to `CodevisorCoreMacTests`; `swift:test` keeps
   running the full suite on macOS.
4. CI: add an iOS verification lane —
   `xcodebuild -project apps/ios/Codevisor.xcodeproj -scheme Codevisor -destination 'generic/platform=iOS Simulator' build`
   plus package tests on an iOS simulator destination. Wire into `bun run check`
   (e.g. `swift:build:ios`).
5. iOS app links `CodevisorCore` and constructs a minimal `AppEnvironment`.

Exit gate: `bun run check` passes with zero macOS source diffs beyond moves and
imports; iOS app builds linking `CodevisorCore`; CI fails if either platform
breaks.

Risks: `AppEnvironment.live()` untangling is the fiddly part — keep macOS
wiring byte-for-byte identical (same defaults, same init order) and lean on the
existing `CodevisorCoreTests` to prove it.

---

## Phase 2 — Shared session + UI layer ("write once, render twice")

Extract the stranded shared logic out of the macOS app target and give the
shared SwiftUI views platform shims so both apps can render them.

Work items:

1. Move AppKit-free session code from `apps/macos/Codevisor/Features/Session/`
   into the package (new `CodevisorSession` target or `CodevisorCore`):
   `SessionController.swift` (2.6k lines), `SessionStore.swift`,
   `TranscriptEnvironment.swift`.
2. New `CodevisorUI` package target for shared SwiftUI + design system:
   - Move `DesignSystem/Motion.swift`, `MarkdownThemeAdapter.swift`,
     `CodeHighlightTheme.swift`, and the token side of `Theme.swift` (palette
     stays in `CodevisorTheming`; system-color fallbacks fork per platform).
   - `CrossKit`-style shims (naming precedent already vendored in
     GhosttySwift): `OSColor`, `OSImage`, `PlatformPasteboard`,
     `PlatformOpenURL`, image cache (`NSCache<NSString, OSImage>`), hover
     (no-op on iOS).
3. `StreamMarkdown` UIKit branches (parser/model untouched):
   - `SelectableTextView.swift` → `UITextView` + TextKit 2 (selection, rounded
     inline-code chip backgrounds)
   - `MarkdownTableView.swift`, `CodeBlockView.swift` (horizontal scroll),
     `MarkdownTextRunView.swift`
   - Snapshot/preview fixtures rendered on both platforms to catch drift.
4. Migrate shared SwiftUI row views into `CodevisorUI` as they're de-AppKit-ed
   (start with the low-hanging ones: `ToolCallRow`, `DiffView`,
   `PlanDocumentView`, `TodoPanelView`, `GoalBannerView`,
   `ConversationItemView`, `AssistantTurnView`, `AttachmentViews`,
   `MessageCopyButton` → pasteboard shim). macOS app consumes them from the
   package — pure moves, no visual change.

Exit gate: macOS app builds entirely against the moved code with no visual or
behavioral change (`swift:test` green, manual smoke via `bun run dev`);
StreamMarkdown test fixtures render on iOS previews.

Risks: TextKit 2 selection/perf parity on iOS; measure with the same fixture
set the macOS views use. Do rows incrementally — each view move is its own
reviewable PR.

---

## Phase 3 — iOS shell: machines, home navigation, worktree dev experience

The app becomes a real Codevisor client you can pair and browse with.

Work items:

1. **Machine pairing & picker**
   - Reuse `MachineController`/`MachineRegistry`/`MachineDeeplink` as-is.
   - Handle `codevisor://` + `codevisor-dev://` URL schemes (add via Xcode MCP
     `AddInfoPlist`); QR scan of the deeplink (the `codevisor setup` output) as
     the flagship pairing flow; manual host+port+token entry as fallback.
   - Machine picker on the home screen (switch `selectedClient`); machine
     health/reachability states; bearer-token storage in Keychain (iOS)
     behind the existing storage seam.
   - ATS: allow plain-HTTP for LAN/Tailscale IPs (loopback already exempt);
     document the HTTPS/Tailscale story for App Store review later.
   - Dev flow: auto-add the machine from `CODEVISOR_DEV_SERVER_URL/TOKEN/NAME`
     launch env (parallels the macOS one-click "add test remote").
2. **Home screen (sidebar, reimagined for touch)**
   - Reuse `ProjectListModel` (1k lines, shared). Native list of
     agents/workspaces/projects with sections matching the macOS sidebar
     organization; drag-to-reorder (`.onMove`) persisting through the same
     repositories so ordering syncs conceptually with macOS.
   - Filter button (top-right) → Liquid Glass popover menu mirroring the macOS
     sidebar filter options (status, harness, project grouping).
   - Live updates via the shared `/v1/events/socket` stream; pull-to-refresh.
   - Machine picker affordance + settings entry point.
3. **Worktree dev-experience parity** (`scripts/dev-ios.mjs`)
   - Per-worktree display name `Codevisor (worktree)` and bundle id suffix
     `com.dylanplayer.codevisor.ios.<instanceHash>` so multiple worktree builds
     coexist on one simulator/device.
   - Generated worktree-colored app icon: port `createDevelopmentAppIcon()` to
     produce an iOS asset catalog icon (same hash→hue derivation, same
     template), so the springboard shows which worktree an app belongs to.
   - Same env plumbing as `scripts/dev.mjs` (`CODEVISOR_DEV_*`), Xcode-MCP
     friendly (scheme env vars for in-Xcode runs).
4. Settings v1: appearance/theme (reuse `ThemeManager` + `AppSettingsModel`),
   machines management, diagnostics toggle.

Exit gate: fresh install → scan QR → browse live projects/workspaces/sessions
of a real machine; two worktrees installed side-by-side with distinct
icons/names; filter menu works.

---

## Phase 4 — Chat: transcript rendering (read path)

The highest-value screen, and the largest genuinely new UI work.

Work items:

1. **iOS transcript host** over the shared `VirtualTranscriptLayout` (built for
   exactly this): a `UIScrollView`-based virtualized, bottom-anchored
   transcript with per-row `UIHostingConfiguration`/hosting views, reusing
   `TranscriptMeasurementLedger` and the anchored-disclosure logic from
   `NativeTranscriptView.swift` (the AppKit twin stays untouched).
   - iOS specifics: keyboard-driven bottom inset, scroll-to-bottom pill,
     rubber-banding + `contentInsetAdjustmentBehavior` correctness.
2. Chat screen assembly reusing shared pieces: `SessionModel`,
   `SessionController`, `TranscriptReducer`, disclosure store, paginated
   history (`initialTranscriptPageSize`/`nextBefore`), per-session WebSocket
   with cursor replay (already reconnect-safe — critical for app
   backgrounding).
3. Remaining row-view ports from Phase 2 land here with real data: tool calls,
   worked items, diffs, plans/todos, goal banner, attachments +
   lightbox (pinch-zoom, share sheet instead of `NSWorkspace.open`), copy
   actions via platform pasteboard shim.
4. Navigation: home → session (NavigationStack push), session header with
   status, background/foreground socket lifecycle (resume via event cursor).

Exit gate: open a long real session; scroll performance validated on device
(120Hz, no hitching on measurement); watch a live streaming turn initiated
from the macOS app; kill/relaunch the app mid-stream and resume losslessly.

Risks: virtualized-transcript perf is the hard engineering here; the layout
engine is shared but iOS hosting-view measurement behaves differently — build
a profiling fixture early (Instruments via Xcode MCP).

---

## Phase 5 — Composer: prompt round-trip (write path)

Codevisor's composer layout (model picker, attachments, submit) rendered as a
first-class iOS input experience.

Work items:

1. **Composer container** docked at the bottom of the chat panel:
   - Always visible; tracks the keyboard exactly (safe-area + keyboard layout
     guide).
   - **Slack-style expand**: drag handle / swipe-up gesture grows the editor to
     the maximum safe height (detent-like behavior, interactive resize, swipe
     down to collapse); smooth handoff between inline and expanded modes.
   - Rebuild `ChatInputEditor` on `UITextView`: multiline growth up to a cap,
     paste-image support, iOS text interactions.
2. **Codevisor controls, iOS ergonomics**: model/mode picker (canonical modes
   shared via `CanonicalMode`), attachment button (photo library, camera,
   Files), submit/cancel button with streaming state, usage ring, harness
   picker where applicable. Layout mirrors the macOS composer's structure,
   restyled per HIG.
3. Reuse shared state: `ComposerDefaultsStore`, `ComposerDraftStore` (drafts
   per session), `ConfigOptionCache`; send/cancel/mode/goal via
   `ServerSessionTransport`.
4. Interactive turn elements: question picker cards (approvals/choices) —
   port `QuestionPickerCard` to shared UI; notifications tie-in comes in
   Phase 8.
5. New-chat flow v1: start a session in an existing project/workspace with
   mode + harness selection (`SessionSetupView` logic shared).

Exit gate: full conversation round-trip from iPhone against the dev remote;
attach a photo; answer a permission question; draft survives app restart;
composer expand/collapse feels native (verified on device).

---

## Phase 6 — Workspaces & panes

The workspace model is shared; the presentation is rethought for one-screen
navigation.

Work items:

1. Reuse `Workspace`, `SplitTree`, `PaneGroupState`, repositories — the pane
   _model_ is identical across platforms; iOS just renders one pane at a time.
2. **Pane navigator**: top-right toolbar button in a workspace opens a
   navigation surface (Liquid Glass sheet/menu) listing the workspace's panes —
   open, add (chat/terminal/scratchpad), rename where applicable, delete;
   badge for active/streaming panes. Optional: horizontal swipe between sibling
   panes.
3. Workspace creation flow (`NewWorkspaceView`/`WorkspaceCreation` logic
   shared): pick project/repo, base branch, worktree creation on the remote
   machine; `RemoteDirectoryBrowserModel` reused for path pickers.
4. Scratchpad pane (shared `ScratchpadModel` + markdown editor on the Phase 2
   text stack).

Exit gate: create a workspace from iPhone, add a second chat pane and a
scratchpad, switch panes via the navigator, delete a pane — state stays
consistent with what the macOS app shows for the same machine.

Status (2026-07-27): first slice shipped. WorkspaceScreen renders one pane at
a time behind a Safari-style pane grid (square.on.square, snapshot previews,
close/add, active ring) with sidebar.left back navigation; pane state
persists client-side via the shared `PaneGroupState` (macOS terminal-key
scheme, one PTY per pane). New Workspace CTA on the home screen → project
picker → instant workspace with a deferred chat pane; harness + run-location
capsule under the composer. Settings sheet holds General / Appearance /
Notifications / Machines / Harnesses / MCPs / Skills. Still open: second chat
panes + scratchpads, remote directory browser / clone in project picker,
pane rename, swipe between panes, zoom transition, deep settings flows
(harness sign-in, MCP add/edit + OAuth, skill import/create, custom themes,
notification sounds).

---

## Phase 7 — Terminal

Terminal is core to the product and fully supported by the existing remote
protocol (`POST /v1/terminals` + WS with `lastOutputSeq` replay; PTYs live
server-side and survive disconnects).

Work items:

1. **Transport**: Swift client for the terminal WS protocol (`input`/`resize`/
   `close` up; `output`/`exit`/`error` down; `clientId` + `clientSeq` dedupe;
   `Authorization` header on the handshake — not the web client's `?token=`),
   with the same reconnect/backoff/replay semantics as
   `apps/web/src/lib/terminal.ts`. Shared target so a future Mac refactor can
   use it too.
2. **Emulator surface**, two-track:
   - Track A (preferred): GhosttyKit for iOS — extend
     `apps/macos/scripts/build-ghostty.sh` for iOS/simulator slices, feed the
     surface from the WS byte stream instead of a spawned proxy (the pattern
     Termini/remux/spectty proved; our vendored GhosttySwift already carries
     upstream's `#if canImport(UIKit)` branches). Keeps rendering +
     `TERM=xterm-ghostty` consistent with macOS.
   - Track B (fallback/de-risk): SwiftTerm view fed by the same transport.
     Decision checkpoint after a 1–2 day spike on Track A.
3. **iOS terminal UX**: keyboard accessory bar (Esc, Ctrl, Tab, arrows, ⌘
   passthrough for hardware keyboards), selection/copy, font size pinch,
   background disconnect → foreground replay (server already holds state).
4. Terminal pane type wired into the Phase 6 pane navigator; background-task
   (external/attach-only) terminals render read-only scrollback.

Exit gate: interactive shell on the paired machine from iPhone; lock the phone
mid-command, reopen, scrollback replays and the process is still running;
works over Tailscale from off-LAN.

---

## Phase 8 — Parity long tail, notifications, polish

Close the gap to full feature parity and make it shippable.

Work items:

1. **Notifications**: `ChatNotificationManager` reuse (UNUserNotificationCenter
   is portable; sounds via `AVAudioPlayer` shim). Local notifications while
   connected; scope the server-side push story (APNs relay) as a follow-on —
   the socket dies in background on iOS, matching the `AppSettings.swift`
   comment about a presence coordinator choosing the receiving device.
2. Feature-parity sweep driven by an audit doc (pattern:
   `docs/macos-tauri-parity.md`): skills & MCP management screens, harness
   management/update banners, session import, goal/plan surfaces, config
   editors, remote browser recents, custom sounds, anything the sweep finds.
3. iPad: `NavigationSplitView` layout (home + detail side-by-side), pointer and
   hardware-keyboard support, Stage Manager sizing.
4. Analytics/diagnostics parity: PostHog + Sentry iOS init (deps already
   iOS-ready), same event taxonomy tagged per-platform.
5. Performance & accessibility pass: Instruments on transcript + terminal,
   Dynamic Type, VoiceOver labels on transcript rows/composer.
6. App identity: production icon set, launch screen, display name.

Exit gate: parity matrix vs the macOS feature list has no unshipped rows
(explicitly N/A rows allowed: local server, Sparkle, computer use, menu bar);
full regression on macOS (`bun run check` + manual smoke) still clean.

---

## Phase 9 — Release readiness (gated on Codevisor LLC account)

1. Move to `com.codevisor.ios` under the LLC team (dev-time IDs were personal +
   never used for an App Store Connect record, so this is a team-picker
   change).
2. TestFlight pipeline: `scripts/release/build-ios-app.sh` (archive, sign,
   upload) mirroring the macOS release script conventions; versioning aligned
   with the server/app release train.
3. App Store prep: privacy manifest/nutrition labels, ATS justification (or
   HTTPS-first pairing), review notes explaining the remote-machine model,
   screenshots.
4. Crash/field monitoring via Xcode MCP (`GetTopCrashIssues`) once TestFlight
   data flows.

---

## Cross-cutting guardrails (every phase)

- **macOS safety**: phases 1–2 are structured as pure moves; every PR runs
  `bun run check` (format, lint, typecheck, JS tests, `swift:test`) plus the
  new iOS build lane. Any macOS visual/behavioral diff is a bug.
- **Testing strategy**: unit tests travel with moved code into package test
  targets (now running for both platforms where platform-neutral); shared-UI
  preview/snapshot fixtures; Xcode MCP interactive verification
  (build/run/tap/hierarchy/logs) as the per-PR smoke loop; XCUITest smoke suite
  from Phase 5 (pair → open session → send prompt).
- **Sequencing/parallelism**: 1 → 2 → 3 → 4 → 5 is the critical path. 6 and 7
  can proceed in parallel after 5 (7's transport work can start after 3).
- **Rough sizing**: P1 M · P2 L · P3 M · P4 L · P5 M/L · P6 M · P7 M/L · P8 L
  (spread) · P9 S/M.

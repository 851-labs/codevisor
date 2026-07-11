# macOS and Tauri parity audit

Last audited: 2026-07-11  
Baseline: `main` at `7f2ec7f` (`v0.1.44`)

## Scope

This audit compares the native macOS app in `apps/macos` with the Tauri/React
app in `apps/desktop` and `apps/web`. It focuses on user-visible session,
transcript, composer, attachment, sidebar, and window behavior. Differences
that are appropriate to each platform, such as Quick Look versus an in-app
lightbox, are not gaps when they provide equivalent outcomes.

The audit is source-based. Existing verification routes were used as component
coverage references, but they do not establish runtime parity by themselves.

## Summary

| Priority | Area               | Missing in Tauri                                                   |
| -------- | ------------------ | ------------------------------------------------------------------ |
| P1       | Transcript scale   | Paginated history, row virtualization, and bounded initial loading |
| P1       | Session inspector  | Info/usage panel and persistent per-session scratchpad             |
| P1       | Compact windows    | Adaptive sidebar and inspector drawers with width hysteresis       |
| P2       | Historical details | On-demand hydration of collapsed worked/tool content               |
| P2       | Disclosures        | Animated reveals and explicit viewport anchoring                   |
| P2       | Attachments        | Preview behavior for generic, non-image files                      |
| P2       | Sidebar            | Waiting/unread state and rename/mark-unread actions                |
| P3       | Worked section     | Persistent header divider while collapsed                          |
| P3       | Sidebar activation | Open sessions on primary pointer-down                              |

## P1 gaps

### 1. Transcript pagination and virtualization

The native app initially requests a bounded transcript page, fetches older
pages near the top of the viewport, and mounts only the visible neighborhood.
Tauri still fetches the complete event stream and renders every conversation
item into the DOM.

Evidence:

- Native pagination: `SessionModel.loadHistory()`,
  `SessionModel.loadOlderHistory()`, and `SessionModel.hasOlderHistory` in
  `apps/macos/Packages/HerdManCore/Sources/HerdManCore/ViewModels/SessionModel.swift`.
- Native virtualization: `VirtualizedTranscriptScrollView` in
  `apps/macos/HerdMan/Features/Session/NativeTranscriptView.swift`.
- Available server endpoints: `GET /v1/sessions/:id/transcript` and
  `GET /v1/sessions/:id/transcript/:itemId/details` in
  `apps/server/src/server.ts`.
- Tauri transport: `sessionEvents()` in `apps/web/src/lib/client.ts`.
- Tauri query: `useSessionDetail()` in `apps/web/src/lib/queries.ts` replays the
  complete event list.
- Tauri rendering: `conversation.map(...)` in
  `apps/web/src/features/session/Transcript.tsx`.

Impact: long sessions have unbounded initial transfer, replay, memory, and DOM
cost. Startup and scroll behavior will increasingly diverge from native as a
session grows.

Acceptance criteria:

- Load the newest bounded transcript page on session entry.
- Fetch older pages without changing the reader's visible anchor.
- Virtualize transcript rows while preserving variable measured heights.
- Preserve follow-latest, session restoration, disclosure state, and the
  scroll-to-bottom affordance.
- Add an end-to-end fixture large enough to prove that the mounted row count is
  bounded independently of total transcript length.

### 2. Session inspector and scratchpad

The native app has a resizable session inspector with Info and Notes tabs. The
Notes tab is a rich-text scratchpad persisted per session, including its open
state. Tauri has no runtime equivalent; similar controls only appear as static
examples in the internal storybook.

Evidence:

- Inspector composition: `SessionInspectorView` and `SessionInfoPanel` in
  `apps/macos/HerdMan/Features/Scratchpad/SessionInspectorView.swift`.
- Notes editor: `ScratchpadNotesView` in
  `apps/macos/HerdMan/Features/Scratchpad/ScratchpadNotesView.swift`.
- Persistence: `ScratchpadModel` and `ScratchpadRepository` under
  `apps/macos/Packages/HerdManCore/Sources/HerdManCore/Scratchpad` and
  `Persistence`.
- Presentation and saved width: `SessionContainerView` in
  `apps/macos/HerdMan/Features/Session/SessionContainerView.swift`.
- No corresponding scratchpad, inspector, or notes persistence exists under
  `apps/web/src`.

Impact: Tauri users cannot inspect usage/cost in the side panel or keep
session-specific notes.

Acceptance criteria:

- Add an Info/Notes inspector reachable from an active session.
- Persist note content and open state per session.
- Persist the selected inspector tab and user-selected docked width.
- Provide keyboard and toolbar access equivalent to native.
- Define a shared persistence contract if notes must follow a session across
  clients; otherwise document that storage is intentionally client-local.

### 3. Adaptive compact-window layout

The native app collapses the inspector below 960 px and the sidebar below
720 px, with separate restore thresholds to prevent flicker. Collapsed panels
become dismissible overlay drawers. Tauri always reserves a fixed 270 px
sidebar and has no inspector drawer.

Evidence:

- Native thresholds, hysteresis, backdrops, animation, and Escape dismissal:
  `AdaptivePanelLayout` and `AdaptiveDrawerLayer` in
  `apps/macos/HerdMan/DesignSystem/AdaptivePanelLayout.swift`.
- Native integration: `ContentView.swift` and
  `Features/Session/SessionContainerView.swift`.
- Fixed Tauri shell: `ShellLayout` in `apps/web/src/routes/_shell.tsx`.

Impact: narrow Tauri windows compress the primary session surface instead of
protecting its usable width. Adding the missing inspector without an adaptive
layout would make this worse.

Acceptance criteria:

- Collapse the trailing inspector before collapsing the leading sidebar.
- Expose collapsed panels through toolbar buttons and edge-aligned drawers.
- Dismiss drawers via backdrop, Escape, route change, and explicit toggle.
- Use hysteresis or an equivalent stable breakpoint strategy.
- Verify at 640, 720, 960, 1000, and 1280 px window widths.

## P2 gaps

### 4. Deferred historical transcript details

Paginated native transcript rows can represent collapsed worked content without
loading all nested details. Expanding the section fetches its details once and
hydrates the turn. Tauri has no transcript-details client method or query.

Evidence:

- Native deferred state and loading: `hasDeferredWorkedDetails`,
  `DeferredTranscriptDetails`, and `loadTranscriptDetails(itemId:)` in
  `AssistantTurnView.swift` and `SessionModel.swift`.
- Tauri only exposes `sessionEvents()` in `apps/web/src/lib/client.ts`.

Impact: this is a prerequisite for matching native's bounded history model.
Without it, Tauri must either load all nested history eagerly or show incomplete
historical disclosures.

Acceptance criteria:

- Decode paginated transcript summaries into the existing React turn model.
- Fetch deferred details only when the user opens an affected disclosure.
- Deduplicate concurrent requests and retain hydrated details for the session.
- Show loading and retry states without collapsing the disclosure.

### 5. Disclosure animation and viewport anchoring

Native worked sections and tool rows animate measured height and opacity while
committing row geometry immediately. The virtualized transcript records an
anchor before disclosure changes and restores it afterward. Tauri mounts or
unmounts disclosure bodies immediately and only animates chevron rotation.

Evidence:

- Native reveals: `WorkedContentReveal` and
  `TranscriptDisclosureContentReveal` in
  `apps/macos/HerdMan/Features/Session/AssistantTurnView.swift`.
- Native anchor transaction: `performAnchoredDisclosureChange` in
  `AssistantTurnView.swift`, `ToolGroupView.swift`, `ToolCallRow.swift`, and
  `NativeTranscriptView.swift`.
- Tauri direct toggles and conditional bodies: `WorkedSection` in
  `apps/web/src/features/session/AssistantTurn.tsx` and disclosure rows in
  `apps/web/src/features/session/ToolGroup.tsx`.

Impact: Tauri disclosures feel abrupt, and browser scroll anchoring is the only
protection against viewport movement when content above the reader changes.

Acceptance criteria:

- Animate reveal height and opacity while honoring `prefers-reduced-motion`.
- Preserve a stable visible transcript anchor across expand and collapse.
- Keep live auto-collapse behavior and persisted disclosure state unchanged.
- Test disclosures above, within, and below the viewport in a long transcript.

### 6. Generic attachment preview

Native Quick Look opens image, PDF, text, source, archive, and other file chips
from both staged composer attachments and transcript messages. Tauri's custom
lightbox handles image/PDF files; a transcript click on another file downloads
it immediately, and the staged generic file chip is inert.

Evidence:

- Native preview entry points: `AttachmentViews.swift` and
  `ComposerView.swift` under `apps/macos/HerdMan/Features`.
- Tauri transcript behavior: `RemoteAttachmentThumb.open()` in
  `apps/web/src/features/attachments/AttachmentPreview.tsx`.
- Tauri staged behavior: `ComposerAttachmentThumb` renders `FileChip` without
  an action in `apps/web/src/features/composer/Composer.tsx`.

Impact: users cannot inspect a generic attachment before sending it, and cannot
preview one from history without initiating a download.

Acceptance criteria:

- Make every staged and sent attachment chip open a preview action.
- Render text and source files in-app where practical.
- For formats requiring an external viewer, use a Tauri opener or a temporary
  local file and make that behavior explicit in the UI.
- Keep download as a separate action rather than overloading preview.

### 7. Sidebar state and session actions

Native session rows distinguish running, waiting-on-user, and unread states,
including an unread count. Their context menus support Rename, Archive, and
Mark as unread. Tauri rows only distinguish running from idle and only expose
Archive.

Evidence:

- Native row state and actions: `SidebarView.swift`, especially
  `unreadCount(for:)`, the session-row `.contextMenu` blocks, and
  `chronologicalSessionRow(...)`.
- Tauri row state and actions: `TrailingSlot`, `SessionRow`, and
  `ChronologicalSessionRow` in
  `apps/web/src/features/sidebar/SessionRow.tsx`.
- `SessionSummary` in `packages/api/src/index.ts` does not currently expose
  unread or waiting-on-user state, so this also requires a shared data contract
  or client-side event-derived state.

Impact: attention-required sessions are less visible in Tauri, and common
session management actions require another surface or are unavailable.

Acceptance criteria:

- Represent running, waiting-on-user, unread, and idle states distinctly.
- Show a stable trailing slot without row-width changes on hover.
- Add Rename and Mark as unread context actions alongside Archive.
- Define how unread state is calculated and persisted across clients.

## P3 gaps

### 8. Worked-section divider

The native worked-section divider belongs to the disclosure header and remains
visible when the section is collapsed. Tauri puts the top border inside the
expanded body, so the divider disappears when collapsed.

Evidence:

- Native: `WorkedSection` in
  `apps/macos/HerdMan/Features/Session/AssistantTurnView.swift`.
- Tauri: `WorkedSection` in
  `apps/web/src/features/session/AssistantTurn.tsx`.

Acceptance criteria:

- Keep the separator visible in collapsed and expanded states.
- Confirm spacing against the internal parity fixture in both themes.

### 9. Pointer-down session activation

Native session rows change selection as soon as the primary pointer goes down.
Tauri uses router links and changes route on click, after pointer-up.

Evidence:

- Native: `sessionActivationGesture(_:)` in
  `apps/macos/HerdMan/Features/Sidebar/SidebarView.swift`.
- Tauri: router `Link` rows in
  `apps/web/src/features/sidebar/SessionRow.tsx`.

Acceptance criteria:

- Navigate on primary pointer-down without breaking drag, modified-click,
  keyboard activation, archive buttons, or context menus.

## Verified parity and intentional differences

- Printable typing focuses the composer in both clients (`2b9891e` for Tauri
  and `62fb642` for native).
- Both clients support image/PDF thumbnails, preview, attachment removal,
  upload progress/failure, and retry. Quick Look on native and a custom
  lightbox in Tauri are appropriate platform-specific implementations.
- Both clients preserve follow-latest behavior, avoid pulling a reader to the
  bottom while reading history, restore per-session scroll state, and expose a
  scroll-to-bottom affordance. Their scaling characteristics differ because
  Tauri is not yet paginated or virtualized.
- Both clients expose slash commands, model/thinking controls, plan and goal
  modes, question prompts, queued prompts, stop, and send behavior.
- The internal Tauri storybook is useful for visual state coverage, but it is
  not a substitute for production-route integration or end-to-end behavior.

## Recommended order

1. Implement paginated transcript transport, deferred detail hydration, and a
   virtualized transcript together. They are one data/rendering architecture
   change and should share fixtures and scroll tests.
2. Add the adaptive panel system, then implement the inspector and scratchpad
   on top of it.
3. Close attachment preview and sidebar state/action gaps.
4. Match disclosure animation/anchoring and the remaining P3 interaction and
   visual details.

Each parity change should update the internal storybook fixture where useful
and add production-route verification for behavior that a static fixture
cannot prove.

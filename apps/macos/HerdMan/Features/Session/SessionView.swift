import SwiftUI
import AppKit
import HerdManCore
import ACPKit

/// A scroll snapshot used to tell user-initiated upward scrolling apart from
/// the transcript growing underneath a pinned viewport, and to save/restore
/// the per-session scroll position.
private struct ScrollSnapshot: Equatable {
    var offsetY: CGFloat
    /// Distance from the visible bottom to the end of the content.
    var distance: CGFloat
    /// The largest reachable content offset.
    var maxOffsetY: CGFloat
    /// The scroll container's visible height — the viewport the culler mounts
    /// rows around.
    var viewportHeight: CGFloat
}

/// The active session screen: a streaming transcript with the composer floating
/// over the bottom of the history (no divider), and enough bottom inset that the
/// last message can scroll clear of the composer.
struct SessionScreen: View {
    @Environment(\.theme) private var theme
    @Bindable var controller: SessionController
    var paneGroup: PaneGroupModel
    /// Pure geometry: whether the end of the content is currently in view.
    /// Drives the scroll-to-bottom button — NOT auto-follow (see
    /// `autoFollow`, which only user intent may change).
    @State private var isAtBottom = true
    /// Whether the transcript follows the stream ("pinned"). Changed only by
    /// user intent: sending a message or scrolling to the bottom pins;
    /// scrolling up any amount unpins. Programmatic follow scrolls never
    /// touch it — deciding this from raw geometry was the old bug, where the
    /// per-flush follow scroll cancelled the user's upward deltas within the
    /// same frame and the transcript felt stuck at the bottom.
    @State private var autoFollow = true
    /// The live scroll phase. While the user's gesture is in flight
    /// (interacting/decelerating), follow scrolls are suspended entirely so
    /// they can never race the gesture; the catch-up happens when the phase
    /// returns to idle.
    @State private var scrollPhase: ScrollPhase = .idle
    /// One geometry tick to skip unpin detection after a programmatic
    /// *upward* correction (the shrink clamp) — the only non-user movement
    /// that decreases the offset.
    @State private var suppressNextUnpin = false
    @State private var composerHeight: CGFloat = 96
    @State private var focus = TerminalFocusController()
    @State private var isQueueExpanded = true
    @State private var isTodosExpanded = true
    @State private var attachmentImages: AttachmentImageStore?
    @State private var scrollPosition = ScrollPosition()
    /// Saved position waiting to be restored precisely (anchored to a
    /// conversation item). Nil once restored (or when the session should
    /// open pinned to the bottom).
    @State private var pendingScrollRestore: SessionScrollState?
    /// Geometry passes spent converging on the restore target; bounded so a
    /// deleted/unreachable anchor can never wedge the restore loop.
    @State private var restoreAttempts = 0
    /// The most recent scroll geometry, so order/width changes can recompute
    /// the culling window without waiting for the next scroll tick.
    @State private var lastSnapshot: ScrollSnapshot?
    /// Coalesces animated width changes (inspector slide, live resize) into
    /// one cache invalidation once the width settles — feeding every
    /// intermediate frame into the culler wipes all row heights per frame.
    @State private var widthSettleTask: Task<Void, Never>?

    /// "End of content is in view" tolerance. Kept just above zero so the
    /// rubber-band rebound after an over-scroll (which eases back into the
    /// bottom edge) doesn't read as scrolling up or flash the
    /// scroll-to-bottom button.
    private static let atBottomThreshold: CGFloat = 2
    /// When the user scrolls back DOWN, re-engage auto-follow once within
    /// this distance of the end. Unpinning is decided by scroll direction
    /// (any upward user scroll), so scrolling up mid-stream disengages
    /// immediately.
    private static let repinDistance: CGFloat = 40

    init(controller: SessionController, paneGroup: PaneGroupModel) {
        self.controller = controller
        self.paneGroup = paneGroup
        // Seed the scroll position so SwiftUI lays the transcript out at the
        // last-read spot during the initial layout — no jump, no animation.
        // Seeding the anchor *item* (not a raw offset) is what makes this
        // accurate: content above the saved spot can change between mounts
        // (turns finish and collapse, new messages arrive), moving raw
        // offsets; an item identity is resolved against the real row. Left
        // at the bottom (or never opened) keeps the pin-to-bottom behavior.
        if let saved = controller.scrollState, !saved.isAtBottom {
            if let anchorID = saved.anchorItemID {
                _scrollPosition = State(initialValue: ScrollPosition(id: anchorID, anchor: .top))
            } else {
                _scrollPosition = State(initialValue: ScrollPosition(y: saved.offsetY))
            }
            _pendingScrollRestore = State(initialValue: saved)
            _isAtBottom = State(initialValue: false)
            _autoFollow = State(initialValue: false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            chatArea

            // The pane-group tab bar sits directly under the chat and stays
            // visible even when the panel content is collapsed; when open it
            // doubles as the panel's resize handle.
            PaneGroupBar(group: paneGroup, onToggle: { togglePanes() })

            if paneGroup.state.isVisible {
                PaneGroupContent(group: paneGroup)
                    .frame(height: paneGroup.state.height)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: paneGroup.state.isVisible)
        .focusedSceneValue(\.terminalToggle, TerminalToggleAction(sessionId: paneGroup.sessionId) {
            togglePanes()
        })
        // Background tasks that stream through a server-owned terminal get a
        // tab in the bottom group — a dev server is something running, not
        // something the chat is waiting on. The tab lives exactly as long as
        // the task: agent kills and completions remove it.
        .onChange(of: controller.backgroundTasks, initial: true) { _, tasks in
            paneGroup.syncAgentTerminals(
                tasks.compactMap { task in
                    task.terminalKey.map { (terminalKey: $0, name: task.description) }
                },
                pruneEnded: controller.hasBackgroundTaskSnapshot
            )
        }
        .onAppear {
            focus.paneGroup = paneGroup
            // ⌘J from inside a focused terminal routes here (the menu command
            // doesn't fire reliably while an AppKit view is first responder).
            paneGroup.requestToggle = { togglePanes() }
            // ⌘W closing the last tab collapses the group; focus returns here.
            paneGroup.requestComposerFocus = { focus.focusComposer() }
            if attachmentImages == nil {
                attachmentImages = AttachmentImageStore { [weak controller] fileId in
                    guard let controller else { throw SessionControllerError.serverUnavailable }
                    return try await controller.fileData(id: fileId)
                }
            }
            // Safety valve: if the restore hasn't converged shortly after
            // mount (content never grew tall enough, anchor never appeared),
            // settle for the closest reachable spot instead of leaving the
            // restore pending forever (`scrollTo` clamps).
            if pendingScrollRestore != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let saved = pendingScrollRestore else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scrollPosition.scrollTo(y: saved.offsetY) }
                    pendingScrollRestore = nil
                }
            } else if autoFollow {
                // Fresh sessions open pinned to the end of the history; the
                // edge position keeps them there as the transcript mounts.
                engageBottomPin(animated: false)
            }
        }
        .environment(\.attachmentImages, attachmentImages)
        .attachmentDropTarget(controller)
    }

    private var chatArea: some View {
        // Scrolling is driven entirely by `scrollPosition` (edge pin, restore
        // offset) and `defaultScrollAnchor`; no `ScrollViewProxy.scrollTo(id:)`
        // remains, so the reader's proxy is intentionally unused.
        ScrollViewReader { _ in
            ScrollView {
                // A plain (non-lazy) stack is deliberate. LazyVStack only
                // *estimates* the heights of unmounted rows, and chat rows
                // range from 20pt tool lines to 320pt diff cards, so the
                // content size was corrected on every mount while scrolling —
                // the scrollbar thumb resized and jumped continuously. Eager
                // layout gives the scroll view an exact content size: one
                // continuous, truthful scrollbar. Mounting everything is
                // affordable because finished turns render collapsed and the
                // expensive per-row work (markdown parsing, shiki, Myers
                // diffs) lives in process-level caches (RenderCaches.swift,
                // DiffRenderCache).
                VStack(alignment: .leading, spacing: 20) {
                    // NOTE: this body reads `settledConversation` (changes at
                    // bubble boundaries) and the boundary-guarded
                    // `hasActiveItem` — never `activeItem`/`conversation`.
                    // Token flushes invalidate ONLY TranscriptActiveItemView;
                    // reading the active bubble here would put the whole
                    // transcript back on the per-flush invalidation path.
                    if controller.settledConversation.isEmpty, !controller.hasActiveItem {
                        if controller.isConnecting || controller.pendingUserText != nil {
                            optimisticStartingTurn
                        }
                        setupSection
                    }
                    ForEach(Array(controller.settledConversation.enumerated()), id: \.element.id) { index, item in
                        // Goal-started sessions open with an agent-initiated
                        // turn (no user message) — the pre-chat setup sections
                        // render above it instead of disappearing.
                        if index == 0, case .assistant = item {
                            setupSection
                        }
                        // Occlusion-culled: renders real content only within a
                        // viewport margin, a fixed-height spacer otherwise, so
                        // per-frame layout is O(visible) not O(conversation).
                        TranscriptRow(item: item, culler: controller.culler)
                        // Pre-chat setup ran between the first message and the
                        // first response; keep the finished sections there.
                        if index == 0, case .user = item {
                            setupSection
                        }
                    }
                    // Goal-started sessions: the agent-initiated bubble is the
                    // first item and lives in the active slot — keep the setup
                    // sections above it.
                    if controller.settledConversation.isEmpty, controller.hasActiveItem {
                        setupSection
                    }
                    TranscriptActiveItemView(controller: controller)
                    if controller.isWaitingOnBackgroundTasks {
                        backgroundTaskIndicator
                    }
                    if let error = controller.errorMessage {
                        errorBanner(error)
                    }
                    Color.clear
                        .frame(height: composerHeight + 24)
                }
                // Lets the id-seeded `ScrollPosition` resolve conversation
                // items as scroll targets (the scroll-restore anchor).
                .scrollTargetLayout()
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .frame(maxWidth: 880, alignment: .leading)
                // The measured column width backs the culler's height cache;
                // a real change invalidates every cached height (rewrapping)
                // so rows remeasure once, then culling re-engages. Animated
                // resizes (inspector slide, live window resize) stream a
                // width per frame — those settle first, so the toggle does
                // zero transcript work mid-flight, exactly like the sidebar
                // (whose toggle never changes the clamped width at all).
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    // The first measurement applies immediately: culling
                    // can't start without a width.
                    if !controller.culler.hasMeasuredWidth {
                        controller.culler.noteWidth(width)
                        recomputeCullingIfPossible()
                        return
                    }
                    widthSettleTask?.cancel()
                    widthSettleTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        controller.culler.noteWidth(width)
                        recomputeCullingIfPossible()
                    }
                }
                .frame(maxWidth: .infinity)
                // While a stream is being followed the viewport scrolls every
                // frame, and each tick rebuilds every row's NSTrackingArea
                // structural region — a per-flush cost that grows with the
                // transcript. Hover affordances are dormant mid-stream.
                .environment(\.hoverTrackingSuspended, controller.isSending)
                // Session-scoped disclosure store so culled rows keep their
                // expand/collapse state across content unmount/remount.
                .environment(\.transcriptDisclosure, controller.disclosure)
            }
            // Open sessions at the end of the history, with no scroll
            // animation. When a saved scroll position exists, the seeded
            // `scrollPosition` (anchored to the last-read item) takes over
            // and the session reopens where the user left it instead.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // THE streaming follow: while pinned, the scroll view itself
            // keeps the viewport glued to the bottom when the content grows —
            // inside its own layout pass, with no per-flush programmatic
            // scrolls (which dragged an extra window layout pass and every
            // row's NSTrackingArea rebuild with them, O(transcript) at
            // 30-60Hz). Unpinned reading is unaffected (`nil` = default
            // resize behavior).
            .defaultScrollAnchor(autoFollow && pendingScrollRestore == nil ? .bottom : nil, for: .sizeChanges)
            .scrollPosition($scrollPosition, anchor: .top)
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geometry in
                ScrollSnapshot(
                    offsetY: geometry.contentOffset.y,
                    distance: geometry.contentSize.height - geometry.visibleRect.maxY,
                    // The largest reachable content offset.
                    maxOffsetY: geometry.contentSize.height + geometry.contentInsets.bottom
                        - geometry.containerSize.height,
                    viewportHeight: geometry.containerSize.height
                )
            } action: { old, new in
                lastSnapshot = new
                // NEVER flip mounts during a user gesture. Mounting a row
                // means laying out its content on the main thread — for a big
                // row (a long assistant answer is one tall row) that's a
                // multi-ms CoreText stall, and any main-thread stall mid-scroll
                // cancels AppKit's trackpad momentum: the "stop sign" halt.
                // Appending below doesn't help — the stall is the layout work,
                // not the position. So the pre-mounted band (a wide margin,
                // built at rest) must cover a gesture's travel; the window is
                // recomputed the moment the scroll settles (phase → .idle).
                // Programmatic scrolls (streaming follow) report no user phase,
                // so they still update.
                if controller.culler.cullingEnabled, !isUserScrollPhase {
                    recomputeCulling(new)
                }

                // A large content collapse (the "Worked for" section of an
                // hours-long turn folding when it finishes) can strand the
                // viewport past the end of the much shorter content, leaving
                // the transcript showing blank space. A shrinking max offset
                // is the discriminator (rubber-band overscroll never shrinks
                // the content), so snap back inside bounds, without animation.
                if pendingScrollRestore == nil,
                   new.maxOffsetY < old.maxOffsetY - 1,
                   new.offsetY > new.maxOffsetY + 1 {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        scrollPosition.scrollTo(y: max(0, new.maxOffsetY))
                    }
                    // The clamp is the one programmatic scroll that moves UP;
                    // don't let its tick read as the user unpinning.
                    suppressNextUnpin = true
                }

                // Pure geometry — drives the scroll-to-bottom button only.
                isAtBottom = new.distance <= Self.atBottomThreshold

                // Auto-follow changes on user intent alone. Follow scrolls
                // only ever move DOWN to the bottom, so an offset decrease is
                // the user (or the clamp, suppressed above) — and while a
                // gesture is in flight, follow scrolls are suspended (the
                // isUserScrollPhase guard below), so the user's upward deltas
                // can't be cancelled out within a tick anymore.
                if pendingScrollRestore == nil {
                    if suppressNextUnpin {
                        suppressNextUnpin = false
                    } else if new.offsetY < old.offsetY - 1,
                              new.distance > Self.atBottomThreshold {
                        // Scrolled up and away from the end — stop following.
                        autoFollow = false
                    } else if !autoFollow,
                              new.offsetY > old.offsetY,
                              new.distance <= Self.repinDistance {
                        // The user scrolled back down to the end — follow
                        // again. While unpinned, every downward move is the
                        // user's: all programmatic follows are gated on the
                        // pin being engaged (or engage it explicitly).
                        autoFollow = true
                    }
                }

                // Backstop for the size-change anchor: whenever pinned growth
                // leaves the viewport short of the bottom, snap to it with a
                // direct offset write (cheap: resolves against the computed
                // content size, no anchor layout pass). Silent when the
                // anchor already kept us glued.
                if pendingScrollRestore == nil, autoFollow, !isUserScrollPhase,
                   new.maxOffsetY > old.maxOffsetY + 1,
                   new.offsetY < new.maxOffsetY - 1 {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        scrollPosition.scrollTo(y: max(0, new.maxOffsetY))
                    }
                }
                handleScrollChange(new)
            }
            .onScrollPhaseChange { _, newPhase in
                scrollPhase = newPhase
                // A gesture replaces the edge pin with a user-owned position;
                // when it ends without unpinning, glue back to the bottom.
                if newPhase == .idle, autoFollow, pendingScrollRestore == nil {
                    engageBottomPin(animated: false)
                }
                // At rest, force an unthrottled window pass so the final
                // position is exact even if the last ticks were throttled.
                if newPhase == .idle {
                    recomputeCullingIfPossible()
                }
            }
            // Streaming follow is a POSITION, not per-flush scroll commands:
            // `scrollTo(edge: .bottom)` pins the viewport and the scroll view
            // keeps itself glued as content grows, inside its normal layout
            // pass. Issuing a scroll per flush — anchored or offset-based —
            // dragged an extra window layout pass and every row's
            // NSTrackingArea rebuild with it, 30-60×/sec, O(transcript):
            // profiled as the dominant main-thread cost on long chats. The
            // pin re-engages on every user-intent transition into following.
            .onChange(of: autoFollow) { _, follows in
                if follows, pendingScrollRestore == nil {
                    engageBottomPin(animated: false)
                }
            }
            .onChange(of: controller.userSendSignal) { _, _ in
                // Sending re-pins unconditionally — even from a restored
                // position or while unpinned reading history.
                pendingScrollRestore = nil
                autoFollow = true
                engageBottomPin(animated: true)
            }
            .onChange(of: paneGroup.state.isVisible) { _, _ in
                // Toggling the panel resizes the chat area; when the user was
                // reading the latest messages, keep them pinned to the bottom
                // instead of letting the panel push the newest content out of view.
                guard pendingScrollRestore == nil, autoFollow else { return }
                engageBottomPin(animated: true)
            }
            // Keep the culler's row order in sync (settled rows only ever
            // append, so count is a sufficient trigger) and seed it on first
            // appearance.
            .onChange(of: controller.settledConversation.count, initial: true) { _, _ in
                controller.culler.setOrder(controller.settledConversation.map(\.id))
                recomputeCullingIfPossible()
            }
            // Cull ONLY while a turn is generating: streaming needs per-frame
            // cost bounded to the visible window, but reading (idle) wants the
            // whole transcript live so trackpad scrolling never mounts anything
            // (mounting a big row mid-scroll stalls momentum). On finish,
            // mount everything; on start, re-engage culling.
            .onChange(of: controller.isSending, initial: true) { _, streaming in
                updateCullingMode(streaming: streaming)
            }
            .overlay(alignment: .bottom) {
                if !isAtBottom {
                    scrollToBottomButton
                        // composerHeight includes the overlay's 24pt top
                        // padding; going past it overlaps the button slightly
                        // onto the composer card's edge.
                        .padding(.bottom, composerHeight - 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .overlay(alignment: .bottom) { composerOverlay }
            .animation(.snappy(duration: 0.2), value: isAtBottom)
        }
    }

    /// Toggles the pane group's content and moves keyboard focus to match
    /// (selected pane on open, composer on close).
    private func togglePanes() {
        let target = paneGroup.toggle()
        // Defer focus until SwiftUI has mounted/removed the panel.
        DispatchQueue.main.async { focus.apply(target) }
    }

    /// Whether the user's scroll gesture (trackpad/wheel interaction or its
    /// momentum) is currently in flight. Programmatic scrolls report
    /// `.animating` or no phase change, so this is a reliable "the user is
    /// scrolling" signal.
    private var isUserScrollPhase: Bool {
        switch scrollPhase {
        case .tracking, .interacting, .decelerating: true
        case .idle, .animating: false
        @unknown default: false
        }
    }

    private var scrollToBottomButton: some View {
        Button {
            autoFollow = true
            engageBottomPin(animated: true)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help("Scroll to bottom")
    }

    /// Finishes the seeded scroll restore, then keeps the saved state current
    /// as the user scrolls. The screen is rebuilt on every session switch
    /// (`.id(session.id)` in `ContentView`), so this is what makes a session
    /// reopen where it was last left instead of at the bottom.
    private func handleScrollChange(_ metrics: ScrollSnapshot) {
        if let saved = pendingScrollRestore {
            restoreTick(saved, metrics)
        } else {
            captureScrollState(metrics)
        }
    }

    /// Records the current position: raw offset plus the topmost visible
    /// item and its distance above the visible top, computed arithmetically
    /// from the culler's height model (no per-row geometry callbacks). The
    /// item anchor is what restores precisely — raw offsets drift when the
    /// content above changes between mounts (turns finish and collapse, new
    /// messages arrive).
    private func captureScrollState(_ metrics: ScrollSnapshot) {
        let anchor = controller.culler.topVisibleRow(contentOffset: metrics.offsetY)
        controller.scrollState = SessionScrollState(
            offsetY: metrics.offsetY,
            anchorItemID: anchor.id,
            anchorDelta: anchor.delta,
            // The pin, not raw geometry: reopening a session resumes
            // following only if the user hadn't scrolled away.
            isAtBottom: autoFollow
        )
    }

    /// One convergence step of the restore. Targets the offset that puts the
    /// saved anchor row back at its saved position relative to the viewport
    /// top, using the current row offset from the height model (which absorbs
    /// content-above changes between mounts). Attempts are bounded so a
    /// deleted/unmeasured anchor can't wedge the loop; the `onAppear` valve
    /// backstops it in time.
    private func restoreTick(_ saved: SessionScrollState, _ metrics: ScrollSnapshot) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        if let anchorID = saved.anchorItemID, let rowTop = controller.culler.rowTop(anchorID) {
            // Offset that reproduces `rowTop - offset == savedDelta`.
            let target = max(0, rowTop - saved.anchorDelta)
            if abs(metrics.offsetY - target) > 1 {
                restoreAttempts += 1
                guard restoreAttempts <= 20 else {
                    pendingScrollRestore = nil
                    return
                }
                withTransaction(transaction) { scrollPosition.scrollTo(y: target) }
                return
            }
            pendingScrollRestore = nil
        } else {
            // Anchor gone (or none captured): the raw offset is the best
            // approximation we have. Wait until it's reachable, jump, done.
            guard metrics.maxOffsetY >= saved.offsetY else { return }
            if abs(metrics.offsetY - saved.offsetY) > 1 {
                withTransaction(transaction) { scrollPosition.scrollTo(y: saved.offsetY) }
            }
            pendingScrollRestore = nil
        }
    }

    /// Engages the native bottom pin. `ScrollPosition.scrollTo(edge:)` sets a
    /// POSITION, not a one-shot command: the scroll view keeps itself glued
    /// to the bottom as content grows/shrinks, within its own layout pass —
    /// no per-flush programmatic scrolls, no deferred catch-up scroll, no
    /// extra layout pass. A user gesture replaces the position (the system
    /// yields), which the unpin logic then records as `autoFollow = false`.
    private func engageBottomPin(animated: Bool) {
        if animated {
            withAnimation(.snappy(duration: 0.18)) { scrollPosition.scrollTo(edge: .bottom) }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollPosition.scrollTo(edge: .bottom) }
        }
    }

    /// Recomputes the occlusion window for the given viewport. Mount flips run
    /// in a no-animation transaction (a content↔spacer swap must never
    /// animate). The mount margin is a full viewport each side — ~10 frames of
    /// runway at a hard fling on 120Hz, so incoming rows mount before they're
    /// on screen.
    private func recomputeCulling(_ snapshot: ScrollSnapshot, minStep: CGFloat = 40) {
        lastSnapshot = snapshot
        let viewport = snapshot.viewportHeight
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            controller.culler.recompute(
                contentOffset: snapshot.offsetY,
                viewportHeight: viewport,
                // Mount two viewports out; don't unmount until three-and-a-half
                // out (hysteresis) so scrolling around a region doesn't thrash
                // rows on/off. During live scroll recompute at most every 40pt
                // of travel; forced (minStep 0) at rest.
                mountMargin: max(viewport * 2, 1200),
                keepMargin: max(viewport * 3.5, 2400),
                minStep: minStep
            )
        }
    }

    /// Re-runs the window against the last known geometry, unthrottled — used
    /// when the row order or column width changes, or at scroll rest.
    private func recomputeCullingIfPossible() {
        if let lastSnapshot { recomputeCulling(lastSnapshot, minStep: 0) }
    }

    /// Switches culling on (streaming) or off (idle). Off mounts every row so
    /// reading scrolls are mount-free and momentum is never interrupted.
    /// `-transcriptCulling NO` forces it permanently off (the pre-culling
    /// transcript) for A/B comparison.
    private func updateCullingMode(streaming: Bool) {
        let allowed = UserDefaults.standard.object(forKey: "transcriptCulling") as? Bool ?? true
        if allowed, streaming {
            controller.culler.cullingEnabled = true
            controller.culler.invalidateWindow()
            recomputeCullingIfPossible()
        } else {
            controller.culler.cullingEnabled = false
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { controller.culler.mountAll() }
        }
    }

    private var composerOverlay: some View {
        VStack(spacing: 8) {
            if let todos = controller.todos, !todos.entries.isEmpty {
                TodoPanelView(plan: todos, isExpanded: $isTodosExpanded)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            // Hidden while editing: the composer IS the goal UI in that mode.
            if controller.supportsGoals, !controller.isGoalEditing,
               let goal = controller.goal ?? controller.draftGoal {
                GoalBannerView(controller: controller, goal: goal)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            if !controller.queuedPrompts.isEmpty {
                PromptQueueView(controller: controller, isExpanded: $isQueueExpanded)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            // A blocking agent question replaces the composer with the picker
            // until it's answered or dismissed (codex CLI behavior). Both plan
            // approvals ride the same picker: Claude's ExitPlanMode question
            // from the runtime, and codex's client-side post-turn prompt.
            if let question = controller.activeQuestion {
                QuestionPickerCard(controller: controller, request: question)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            } else {
                ComposerCard(
                    controller: controller,
                    placeholder: "Ask for follow-up changes",
                    onTextViewReady: { focus.composerTextView = $0 }
                )
            }
            statusLabel
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 880)
        .padding(.bottom, 16)
        .padding(.top, 24)
        // The fade sits behind the composer column only (not the full row
        // width), so transcript text in the side gutters stays legible.
        .background(
            LinearGradient(
                colors: [
                    theme.windowBackground.opacity(0),
                    theme.windowBackground.opacity(0.9),
                    theme.windowBackground
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // Start the fade a touch above the overlay's own bounds without
            // affecting layout (inset or scroll-button anchoring).
            .padding(.top, -12)
            .allowsHitTesting(false)
        )
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        .animation(.snappy(duration: 0.2), value: controller.queuedPrompts.map(\.id))
        .animation(.snappy(duration: 0.2), value: isQueueExpanded)
    }

    /// The "Setting up worktree…" / "Starting <harness>…" sections for a
    /// brand-new session: live timers and streamed logs while pre-chat setup
    /// runs, collapsing to "Set up worktree in 60s" once done.
    @ViewBuilder
    private var setupSection: some View {
        if !controller.setupPhases.isEmpty {
            SessionSetupView(phases: controller.setupPhases)
        }
    }

    @ViewBuilder
    private var optimisticStartingTurn: some View {
        // The pending prompt is held by the controller from the instant the
        // user sends (the composer is cleared immediately); fall back to the
        // composer for the pre-send connecting state.
        let text = (controller.pendingUserText
            ?? controller.composerText.trimmingCharacters(in: .whitespacesAndNewlines))
        if !text.isEmpty || !controller.pendingUserAttachments.isEmpty {
            UserMessageView(message: UserMessage(text: text, attachments: controller.pendingUserAttachments))
            // The setup sections narrate pre-chat progress with their own
            // timers; the generic shimmer only covers flows without them.
            if controller.setupPhases.isEmpty {
                ShimmeringText.startingAgent
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch controller.status {
        case .connecting:
            EmptyView()
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(theme.statusWarn)
        case .idle:
            EmptyView()
        }
    }

    /// Shown between turns while the agent owns background work (backgrounded
    /// shells, subagents) — the agent restarts on its own when it settles, so
    /// the chat is waiting, not stuck. Hidden the moment a turn is in flight.
    @ViewBuilder
    private var backgroundTaskIndicator: some View {
        if let task = controller.waitingBackgroundTasks.first {
            let extra = controller.waitingBackgroundTasks.count - 1
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ShimmeringText.waitingOnBackgroundTask(
                    extra > 0 ? "\(task.description) and \(extra) more" : task.description
                )
                Spacer(minLength: 0)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(theme.statusError)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.statusError.opacity(0.1)))
    }

}

/// The one transcript row that re-renders on token flushes. Deliberately the
/// ONLY view whose body reads `controller.activeItem`: Observation scopes
/// invalidation to the body that read the property, so streaming updates
/// re-evaluate this subtree alone while the settled ForEach above stays
/// inert. Folding this read into the transcript container's body would put
/// every row back on the per-flush AttributeGraph diff — the O(transcript)
/// cost that made streaming degrade with conversation length.
private struct TranscriptActiveItemView: View {
    let controller: SessionController

    var body: some View {
        if let item = controller.activeItem {
            ConversationItemView(item: item)
                // Stable explicit identity: the item id only changes when a
                // new bubble starts, and it keeps the row resolvable as a
                // scroll-restore target while it is still the active slot.
                .id(item.id)
        }
    }
}

private struct PromptQueueView: View {
    @Environment(\.theme) private var theme
    @Bindable var controller: SessionController
    @Binding var isExpanded: Bool
    @State private var editingQueueId: String?
    @State private var editingQueueText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Queue")
                        .font(.caption.weight(.semibold))
                    Text(queueCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.queuedPrompts) { item in
                        queueRow(item)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.composerBackground.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func queueRow(_ item: ServerPromptQueueItem) -> some View {
        if editingQueueId == item.id {
            HStack(spacing: 8) {
                TextField("Queued message", text: $editingQueueText)
                    .textFieldStyle(.plain)
                Button {
                    Task {
                        await controller.updateQueuedPrompt(id: item.id, text: editingQueueText)
                        editingQueueId = nil
                    }
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.plain)
                .help("Save")
                Button {
                    editingQueueId = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
            .font(.caption)
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .foregroundStyle(.tertiary)
                Text(item.text)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    editingQueueId = item.id
                    editingQueueText = item.text
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("Edit queued message")
                Button {
                    Task { await controller.deleteQueuedPrompt(id: item.id) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Remove queued message")
            }
            .font(.caption)
        }
    }

    private var queueCountText: String {
        let count = controller.queuedPrompts.count
        return count == 1 ? "1 message" : "\(count) messages"
    }
}

#if DEBUG
#Preview("Conversation") {
    SessionScreen(
        controller: .preview(model: .preview()),
        paneGroup: previewPaneGroup()
    )
    .frame(width: 900, height: 680)
}

#Preview("With terminal") {
    let group = previewPaneGroup()
    group.toggle()
    return SessionScreen(controller: .preview(model: .preview()), paneGroup: group)
        .frame(width: 900, height: 680)
}

private func previewPaneGroup() -> PaneGroupModel {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/shepherd"))
    let session = ChatSession(projectId: project.id, title: "Preview")
    return PaneGroupModel(
        sessionId: session.id,
        repository: DefaultPaneGroupRepository(store: InMemoryStore()),
        makeContext: { descriptor in
            PaneContext(
                paneId: descriptor.id,
                sessionId: session.id,
                terminalKey: descriptor.terminalKey,
                attachOnly: descriptor.attachOnly,
                machine: .local,
                session: session,
                project: project
            )
        }
    )
}
#endif

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
    /// The transcript rows' frames in scroll-view space, used to anchor
    /// save/restore to real items instead of raw offsets (item anchors
    /// survive content changing while the session was closed — new
    /// messages, turns finishing and collapsing).
    @State private var itemFrames = TranscriptItemFrames()
    private let bottomID = "session-bottom"

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
            }
        }
        .environment(\.attachmentImages, attachmentImages)
        .attachmentDropTarget(controller)
    }

    private var chatArea: some View {
        ScrollViewReader { proxy in
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
                    if controller.conversation.isEmpty {
                        if controller.isConnecting || controller.pendingUserText != nil {
                            optimisticStartingTurn
                        }
                        setupSection
                    }
                    ForEach(Array(controller.conversation.enumerated()), id: \.element.id) { index, item in
                        // Goal-started sessions open with an agent-initiated
                        // turn (no user message) — the pre-chat setup sections
                        // render above it instead of disappearing.
                        if index == 0, case .assistant = item {
                            setupSection
                        }
                        ConversationItemView(item: item)
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .scrollView)
                            } action: { frame in
                                itemFrames.frames[item.id] = frame
                            }
                            .onDisappear { itemFrames.frames[item.id] = nil }
                        // Pre-chat setup ran between the first message and the
                        // first response; keep the finished sections there.
                        if index == 0, case .user = item {
                            setupSection
                        }
                    }
                    if controller.isWaitingOnBackgroundTasks {
                        backgroundTaskIndicator
                    }
                    if let error = controller.errorMessage {
                        errorBanner(error)
                    }
                    Color.clear
                        .frame(height: composerHeight + 24)
                        .id(bottomID)
                }
                // Lets the id-seeded `ScrollPosition` resolve conversation
                // items as scroll targets (the scroll-restore anchor).
                .scrollTargetLayout()
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // Open sessions at the end of the history, with no scroll
            // animation. When a saved scroll position exists, the seeded
            // `scrollPosition` (anchored to the last-read item) takes over
            // and the session reopens where the user left it instead.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollPosition($scrollPosition, anchor: .top)
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geometry in
                ScrollSnapshot(
                    offsetY: geometry.contentOffset.y,
                    distance: geometry.contentSize.height - geometry.visibleRect.maxY,
                    // The largest reachable content offset.
                    maxOffsetY: geometry.contentSize.height + geometry.contentInsets.bottom
                        - geometry.containerSize.height
                )
            } action: { old, new in
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
                // gesture is in flight, follow scrolls are suspended (see
                // the streamFingerprint guard), so the user's upward deltas
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
                handleScrollChange(new)
            }
            .onScrollPhaseChange { _, newPhase in
                scrollPhase = newPhase
                // Catch up after a gesture ends: content that streamed in
                // while follows were suspended is scrolled into view, but
                // only if the gesture didn't unpin.
                if newPhase == .idle, autoFollow, pendingScrollRestore == nil {
                    scrollToBottom(proxy, animated: false)
                }
            }
            .onChange(of: controller.userSendSignal) { _, _ in
                // Sending re-pins unconditionally — even from a restored
                // position or while unpinned reading history.
                pendingScrollRestore = nil
                autoFollow = true
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: streamFingerprint) { _, _ in
                // Follow the stream only while pinned, never while a saved
                // position is being restored (transcript mounting fires this
                // too), and never while the user's scroll gesture is in
                // flight — racing the gesture was how "scroll up during a
                // long turn" got stuck at the bottom.
                guard pendingScrollRestore == nil, autoFollow, !isUserScrollPhase else { return }
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: composerHeight) { _, _ in
                // `autoFollow` is seeded false for restored sessions, so this
                // pin can't yank a restored position back to the bottom.
                if pendingScrollRestore == nil, autoFollow, !isUserScrollPhase {
                    scrollToBottom(proxy, animated: false)
                }
            }
            .onChange(of: paneGroup.state.isVisible) { _, _ in
                // Toggling the panel resizes the chat area; when the user was
                // reading the latest messages, keep them pinned to the bottom
                // instead of letting the panel push the newest content out of view.
                guard pendingScrollRestore == nil, autoFollow else { return }
                scrollToBottom(proxy, animated: true)
                // Re-pin once the panel's show/hide animation has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    scrollToBottom(proxy, animated: false)
                }
            }
            .onChange(of: paneGroup.state.height) { _, _ in
                guard pendingScrollRestore == nil, paneGroup.state.isVisible, autoFollow else { return }
                scrollToBottom(proxy, animated: false)
            }
            .overlay(alignment: .bottom) {
                if !isAtBottom {
                    scrollToBottomButton(proxy)
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

    private func scrollToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            autoFollow = true
            scrollToBottom(proxy, animated: true)
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
    /// item and its distance above the visible top. The item anchor is what
    /// restores precisely — raw offsets drift when the content above changes
    /// between mounts (turns finish and collapse, new messages arrive).
    private func captureScrollState(_ metrics: ScrollSnapshot) {
        var anchorID: UUID?
        var anchorMinY = CGFloat.greatestFiniteMagnitude
        for (id, frame) in itemFrames.frames where frame.maxY > 0 && frame.minY < anchorMinY {
            anchorID = id
            anchorMinY = frame.minY
        }
        controller.scrollState = SessionScrollState(
            offsetY: metrics.offsetY,
            anchorItemID: anchorID,
            anchorDelta: anchorID == nil ? 0 : -anchorMinY,
            // The pin, not raw geometry: reopening a session resumes
            // following only if the user hadn't scrolled away.
            isAtBottom: autoFollow
        )
    }

    /// One convergence step of the restore. The id-seeded `ScrollPosition`
    /// makes SwiftUI lay the transcript out with the anchor item at the top
    /// edge; this only waits for the anchor row to exist and then nudges by
    /// the saved intra-item delta (instantly, never animated). Attempts only
    /// count issued scroll commands — mount churn produces many geometry
    /// ticks and must not exhaust the budget. Falls back to the raw offset
    /// when the anchor no longer exists; the `onAppear` valve bounds the
    /// whole thing in time.
    private func restoreTick(_ saved: SessionScrollState, _ metrics: ScrollSnapshot) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        if let anchorID = saved.anchorItemID,
           controller.conversation.contains(where: { $0.id == anchorID }) {
            guard let frame = itemFrames.frames[anchorID] else {
                // The seeded position mounts the anchor during initial
                // layout; nothing to do but wait (the valve backstops a row
                // that never materializes).
                return
            }
            // How far the anchor sits below where the user left it.
            let error = frame.minY + saved.anchorDelta
            if abs(error) > 1 {
                restoreAttempts += 1
                guard restoreAttempts <= 20 else {
                    pendingScrollRestore = nil
                    return
                }
                withTransaction(transaction) { scrollPosition.scrollTo(y: metrics.offsetY + error) }
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

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
        if animated {
            withAnimation(.snappy(duration: 0.18)) { action() }
        } else {
            action()
        }

        // Markdown and overlay layout can grow on the next pass while streaming;
        // a deferred scroll keeps the real bottom aligned instead of stopping a
        // few points above the latest content.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.snappy(duration: 0.18)) { action() }
            } else {
                action()
            }
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
            // until it's answered or dismissed (codex CLI behavior).
            if let pendingQuestion = controller.pendingQuestion {
                QuestionPickerCard(controller: controller, request: pendingQuestion)
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

    private var streamFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(controller.conversation.count)
        hasher.combine(controller.isWaitingOnBackgroundTasks)
        if case let .assistant(message) = controller.conversation.last {
            hasher.combine(message.turn.entries.count)
            // The finalize flip matters: the worked section auto-collapses on
            // it, and a pinned viewport must follow the shrink to the new
            // bottom instead of being left mid-air.
            hasher.combine(message.turn.isGenerating)
            hasher.combine(message.turn.isThinking)
            hasher.combine(message.turn.subagentActivityFingerprint)
            if case let .text(_, markdown) = message.turn.finalText {
                hasher.combine(markdown.count)
            }
        }
        return hasher.finalize()
    }
}

/// The transcript rows' frames in scroll-view space. A plain class held in
/// `@State`: the frames update on every scroll frame, so they must not be
/// observable state (that would re-render the transcript per tick).
@MainActor
private final class TranscriptItemFrames {
    var frames: [UUID: CGRect] = [:]
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

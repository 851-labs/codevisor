import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI

extension Notification.Name {
    static let codevisorOpenSettings = Notification.Name("codevisor.open-settings")
}

/// Animates one stable user row for one targeted send request. This does not
/// depend on whether SwiftUI observes the request before or after the row is
/// inserted, and the row keeps this state when optimistic content settles.
private struct UserSendLiftModifier: ViewModifier {
    private static let animation: Animation = .snappy(duration: 0.38)

    let messageID: UUID?
    let distance: CGFloat
    let request: UserSendAnimationRequest?
    let controller: SessionController
    let reduceMotion: Bool
    let geometryReady: Bool
    @State private var offset: CGFloat = 0
    @State private var runningToken: UInt64?

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .onAppear { animateIfNeeded() }
            .onChange(of: request?.token) { _, _ in animateIfNeeded() }
            .onChange(of: geometryReady) { _, _ in animateIfNeeded() }
    }

    private func animateIfNeeded() {
        guard let request,
              messageID == request.messageID
        else { return }
        // A newly promoted chat renders its optimistic row before SwiftUI has
        // reported the transcript tail and composer positions. Do not spend
        // the exactly-once token on the minimum-distance placeholder; the
        // geometry change above retries as soon as both anchors are real.
        guard reduceMotion || geometryReady else { return }
        guard controller.claimUserSendAnimation(request) else { return }
        guard !reduceMotion else {
            offset = 0
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = distance
        }
        runningToken = request.token
        // A separate main-run-loop turn commits the source offset before the
        // destination transaction begins. `Task.yield()` may resume within the
        // same SwiftUI update and collapse both states into no animation.
        DispatchQueue.main.async {
            guard runningToken == request.token else { return }
            withAnimation(Self.animation) {
                offset = 0
            }
        }
    }
}

/// One row of the transcript, whatever the chat's connection state. The whole
/// chat — an optimistic first message, worktree setup, settled turns, the
/// streaming turn, loading and error status — is ONE ordered list of these,
/// exactly like the macOS `ChatScreen`'s row builder.
///
/// This replaced three parallel scroll views (a connected transcript, a
/// model-less "pending setup" column, and a model-less status column) that each
/// re-implemented the same rows. Every visual inconsistency between "the first
/// message in a new chat" and "a message in an existing chat" came from that
/// fork: the send animation, the setup row's placement, and the loading/error
/// rows all existed in two or three copies that drifted apart.
private enum TranscriptRow: Identifiable {
    /// Sentinel that pages in older history as it scrolls into view.
    case olderHistory
    /// Worktree creation / agent startup for this chat's one launch.
    case setup
    /// A settled, streaming, or optimistic conversation item. A first prompt
    /// is created before its model and retains this row identity when it
    /// settles, so SwiftUI never removes and reinserts the sent bubble.
    case item(ConversationItem, isActive: Bool)
    case activity(ActivityKind)
    /// A session failure, which may offer harness authentication.
    case sessionError(String)
    /// A connection failure, which offers a plain retry.
    case statusError(String)

    enum ActivityKind: Equatable {
        case loadingHistory
        case startingAgent
        case connecting(String)
        case serverWait(String)

        var id: String {
            switch self {
            case .loadingHistory: "loading-history"
            case .startingAgent: "starting-agent"
            case .connecting: "connecting"
            case .serverWait: "server-wait"
            }
        }
    }

    var id: String {
        switch self {
        case .olderHistory: "older-history"
        case .setup: "setup"
        case let .item(item, isActive): "item-\(isActive ? "active-" : "")\(item.id)"
        case let .activity(kind): "activity-\(kind.id)"
        case .sessionError: "session-error"
        case .statusError: "status-error"
        }
    }
}

/// The chat pane body: connects an existing session through the shared
/// SessionController/SessionModel engine and renders the transcript with the
/// shared row views. Hosted by WorkspaceScreen, which owns the navigation
/// chrome; the VirtualTranscriptLayout-backed virtualizer replaces the scroll
/// host as Phase 4 completes.
struct SessionTranscriptView: View {
    @Bindable var controller: SessionController
    /// The new-chat page shows project/run-location chips above the composer;
    /// the first chat inside a workspace doesn't (its directory is fixed).
    /// This flag is the only difference between the two surfaces — everything
    /// else (watermark, composer, expansion, notice rails) is shared here.
    var showsRunPickers: Bool = false
    /// New Chat supplies one request for its initial presentation. Existing
    /// chats leave this nil and never steal keyboard focus when opened.
    var initialComposerFocusRequest: UUID? = nil
    var onInitialComposerFocusRequestFulfilled: ((UUID) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var disclosure = TranscriptDisclosureStore()
    /// The composer's resting height, used to size the transcript's bottom
    /// spacer and the mask that sits under the card.
    @State private var composerHeight: CGFloat = 96
    /// True while the transcript is parked at the newest content; drives both
    /// auto-scroll and the scroll-to-bottom button, mirroring the macOS
    /// transcript's follow mode.
    @State private var followsLatest = true
    @State private var isAtBottom = true
    /// Bumped to ask the scroll view to return to the newest content.
    @State private var scrollRequest = 0
    /// Height available to the chat area, used to cap composer expansion.
    @State private var availableHeight: CGFloat = 600
    /// True while the composer is dragged to full height; the accessories
    /// around it (scroll-to-bottom, notice rails) hide until it collapses.
    @State private var composerExpanded = false
    /// The scroll view's own height: the transcript fills at least this much
    /// so a short conversation starts at the top instead of floating at the
    /// bottom of the viewport.
    @State private var viewportHeight: CGFloat = 0
    /// Fetches and caches transcript attachment previews via the controller's
    /// authenticated client.
    @State private var attachmentImages: AttachmentImageStore?
    /// Edge-based scrolling for follow mode: unlike ScrollViewReader's
    /// id-targeted scrollTo, scrolling to an edge works even when the bottom
    /// rows haven't been laid out by the lazy stack yet.
    @State private var scrollPosition = ScrollPosition()
    /// Where the transcript's content currently ends, and where the composer
    /// begins — both in global space. Their gap IS the send lift: the distance
    /// a just-sent message must travel from the composer to where it lands.
    /// Measuring beats assuming, because the landing spot moves: a short
    /// conversation is top-aligned with slack beneath it (long ride), while a
    /// full one sits against the composer (short hop).
    @State private var contentTailY: CGFloat = 0
    @State private var composerTopY: CGFloat = 0
    /// First-send promotion mounts a brand-new transcript whose global
    /// coordinates arrive asynchronously. The send token remains unclaimed
    /// until both anchors have reported at least once.
    @State private var hasMeasuredContentTail = false
    @State private var hasMeasuredComposerTop = false
    /// The transcript's first content is a screen opening, not a change to
    /// follow: jump to the bottom, don't animate the scroll there.
    @State private var hasOpened = false

    var body: some View {
        chat
        .onAppear { [controller] in
            if attachmentImages == nil {
                attachmentImages = AttachmentImageStore { [weak controller] fileId in
                    guard let controller else { throw SessionControllerError.serverUnavailable }
                    return try await controller.fileData(id: fileId)
                }
            }
        }
        .environment(\.attachmentImages, attachmentImages)
    }

    private var model: SessionModel? { controller.model }

    /// The watermark shows while the transcript has nothing to say at all — a
    /// model-less draft (new-worktree chats deliberately don't connect until
    /// first send) or an empty conversation. Equivalent to `rows.isEmpty`, but
    /// O(1): the body re-evaluates on every streaming token, so this must not
    /// build the row list.
    private var showsWatermark: Bool {
        guard controller.pendingUserMessage == nil, controller.setupPhases.isEmpty else { return false }
        guard controller.sessionErrorMessage == nil else { return false }
        guard !controller.isLoadingInitialHistory, controller.serverWaitMessage == nil else { return false }
        switch controller.status {
        case .connecting, .failed: return false
        case .idle: break
        }
        guard let model else { return true }
        return model.settledConversation.isEmpty && model.activeItem == nil
    }

    /// The scroll-to-bottom button only means something once there's a
    /// conversation to scroll through.
    private var hasScrollableContent: Bool {
        guard let model else { return false }
        return !model.settledConversation.isEmpty || model.activeItem != nil
    }

    // MARK: - The row list

    /// The whole chat as one ordered list, in macOS's order. Every state — no
    /// model yet, connecting, streaming, failed — is expressed here rather than
    /// by swapping in a different scroll view.
    private var rows: [TranscriptRow] {
        var rows: [TranscriptRow] = []
        let settled = model?.settledConversation ?? []
        let active = model?.activeItem
        let hasSetup = !controller.setupPhases.isEmpty
        let pendingMessage = controller.pendingUserMessage.flatMap { pending in
            settled.contains(where: { item in
                if case let .user(message) = item { return message.id == pending.id }
                return false
            }) ? nil : pending
        }
        let pendingIsOpeningRow = settled.isEmpty && active == nil

        if model?.hasOlderHistory == true {
            rows.append(.olderHistory)
        }

        // The opening block: the conversation hasn't landed yet. Covers the
        // first send (with or without a model) and an empty connected chat.
        if settled.isEmpty, active == nil {
            if let message = pendingMessage {
                rows.append(.item(.user(message), isActive: false))
                // Until the first phase arrives there's nothing to show but
                // that something is happening.
                if !hasSetup { rows.append(.activity(.startingAgent)) }
            }
            if hasSetup { rows.append(.setup) }
            if controller.isLoadingInitialHistory {
                rows.append(.activity(.loadingHistory))
            } else if pendingMessage == nil {
                if let message = controller.serverWaitMessage {
                    rows.append(.activity(.serverWait(message)))
                } else if case let .connecting(message) = controller.status {
                    rows.append(.activity(.connecting(message)))
                }
            }
        }

        // Setup is anchored to the START of the conversation — the one time it
        // ran: ahead of a leading assistant turn, or right after the first user
        // message, whose send triggered it.
        for (index, item) in settled.enumerated() {
            if index == 0, hasSetup, isAssistant(item) { rows.append(.setup) }
            rows.append(.item(item, isActive: false))
            if index == 0, hasSetup, isUser(item) { rows.append(.setup) }
        }

        if settled.isEmpty, active != nil, hasSetup { rows.append(.setup) }
        if let active { rows.append(.item(active, isActive: true)) }
        if !pendingIsOpeningRow, let message = pendingMessage {
            rows.append(.item(.user(message), isActive: false))
        }

        if !settled.isEmpty || active != nil {
            if controller.isLoadingInitialHistory {
                rows.append(.activity(.loadingHistory))
            }
            if let message = controller.serverWaitMessage {
                rows.append(.activity(.serverWait(message)))
            }
        }

        if let message = controller.sessionErrorMessage {
            rows.append(.sessionError(message))
        }
        if case let .failed(message) = controller.status, message != controller.sessionErrorMessage {
            rows.append(.statusError(message))
        }
        return rows
    }

    /// One chat surface for every connection state. The composer is mounted
    /// exactly once — reconnects (run-location changes, harness switches)
    /// swap only the content behind it, so drafts keep their text, focus,
    /// and attachments, just like the macOS composer. Connecting reads as an
    /// inline status line, never a screen takeover.
    private var chat: some View {
        // Deliberately not wrapped in a GeometryReader: that opts the subtree
        // out of SwiftUI's keyboard avoidance, which left the composer sitting
        // underneath the keyboard.
        ZStack(alignment: .bottom) {
            if showsWatermark {
                Image("hunk")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 130)
                    .foregroundStyle(Color.primary.opacity(0.08))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    // Center in the space the user can actually see — above
                    // the composer — and let keyboard avoidance (which
                    // shrinks this ZStack) float it upward, Grok-style.
                    .padding(.bottom, composerHeight + 20)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            // ONE transcript for every connection state, always mounted — so a
            // row's transition actually runs (SwiftUI skips a child's
            // transition when the parent itself is what got inserted, which is
            // why the old model-less column needed a hand-rolled offset) and so
            // rows can never disagree between states.
            transcript

            VStack(spacing: 8) {
                // A fully-expanded composer is a focused writing surface: the
                // accessories above it hide and return on collapse.
                if !composerExpanded {
                    if !isAtBottom, hasScrollableContent {
                        HStack {
                            Spacer()
                            scrollToBottomButton
                        }
                        .transition(.opacity)
                    }
                    composerNoticeRail
                        .transition(.opacity)
                }
                ComposerBar(
                    controller: controller,
                    // Dragged fully open, the card reaches all the way up to
                    // the top bar (a hair of breathing room; the run-picker
                    // chips keep their slot above it on the new-chat page);
                    // text-driven auto-resize keeps its own, much lower cap
                    // inside ComposerBar.
                    maxHeight: availableHeight - 12,
                    collapsedHeight: $composerHeight,
                    isExpanded: $composerExpanded,
                    showsRunPickers: showsRunPickers,
                    initialFocusRequest: initialComposerFocusRequest,
                    onInitialFocusRequestFulfilled:
                        onInitialComposerFocusRequestFulfilled
                )
                // Where a sent message starts its ride. Measured rather than
                // assumed: the row has to travel from HERE to wherever it
                // lands, and those two points are far apart in a short
                // conversation and adjacent in a long one.
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                    composerTopY = top
                    hasMeasuredComposerTop = true
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            availableHeight = height
        }
        // The watermark hands the space over rather than blinking out.
        .animation(Motion.quick(reduceMotion: reduceMotion), value: showsWatermark)
        // Tab snapshots crop the composer out so previews show only content.
        .onChange(of: composerHeight, initial: true) { _, height in
            PaneSnapshotCache.shared.activeBottomChrome = height + 6
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var composerNoticeRail: some View {
        if let message = controller.configurationValidationError {
            ComposerNoticeRail(
                message,
                kind: .error,
                actionTitle: "Retry",
                action: {
                    Task { await controller.retryExistingSessionCapabilities() }
                }
            )
        } else if let message = controller.configurationAdjustmentMessage {
            ComposerNoticeRail(
                message,
                kind: .warning,
                onDismiss: { controller.dismissConfigurationAdjustment() }
            )
        }
    }

    private var scrollToBottomButton: some View {
        Button {
            followsLatest = true
            scrollRequest &+= 1
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        // The same Liquid Glass treatment as the macOS transcript's button.
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel("Scroll to bottom")
    }

    private static let bottomAnchor = "transcript-bottom"

    private func isUser(_ item: ConversationItem) -> Bool {
        if case .user = item { return true }
        return false
    }

    private func isAssistant(_ item: ConversationItem) -> Bool {
        if case .assistant = item { return true }
        return false
    }

    // MARK: - The send lift

    /// Even when the content already ends at the composer, start a hair behind
    /// the card so the row emerges from under it rather than appearing on its
    /// edge.
    private static let minimumSendLift: CGFloat = 18

    /// One rule for every sent message, in every chat state: start at the
    /// composer and travel to wherever the row lands. The distance is the
    /// measured gap between the content's tail and the composer's top — a long
    /// ride in an empty or short conversation, a short hop in a full one.
    ///
    /// Measured, not assumed. A constant here (the earlier bug) is only correct
    /// when the conversation is long enough to sit against the composer; in a
    /// short one the row lands high on the screen, and a constant made it pop
    /// in just below its destination instead of rising out of the composer.
    private var sendLift: CGFloat {
        max(Self.minimumSendLift, composerTopY - contentTailY)
    }

    /// The one transcript. Always mounted, whatever the chat's state; its
    /// content is `rows`.
    private var transcript: some View {
        // Built once per render: the body re-evaluates on every streaming
        // token, and this walks the whole conversation.
        let rows = rows
        return ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(rows) { row in
                        transcriptRow(row, scroller: scroller)
                    }

                    // Breathing room past the composer so the newest content
                    // can clear it, and the measurement point for where the
                    // content currently ends.
                    Color.clear
                        .frame(height: composerHeight + 24)
                        .id(Self.bottomAnchor)
                        .onScrollVisibilityChange(threshold: 0.05) { visible in
                            isAtBottom = visible
                            followsLatest = visible
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { tail in
                            contentTailY = tail
                            hasMeasuredContentTail = true
                        }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(minHeight: viewportHeight, alignment: .top)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                viewportHeight = height
            }
            .scrollPosition($scrollPosition)
            // The lazy stack's estimated row heights make the indicator grow
            // and shrink as content materializes; hide it until the virtualizer
            // provides stable content sizing.
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .environment(\.transcriptDisclosure, disclosure)
            .environment(\.transcriptController, controller)
            .environment(\.runningSubagentToolCallIds, controller.runningSubagentToolCallIds)
            // Too-wide tables bleed their horizontal scroller through the
            // transcript's 16pt text gutter to the screen edges (text keeps the
            // gutter; a resting table stays aligned with it).
            .environment(\.markdownTableBleed, 16)
            // Streaming tokens and settled turns re-pin while following.
            .onChange(of: model?.activeItemRevision) { _, _ in
                scrollToBottomIfFollowing(scroller)
            }
            .onChange(of: model?.settledConversation.count) { _, _ in
                scrollToBottomIfFollowing(scroller)
            }
            // Sending re-arms follow and returns to the newest content —
            // exactly what the macOS transcript does (`autoFollow = true` plus
            // a scroll command), so the response streams in at the bottom with
            // the view following it.
            .onChange(of: controller.userSendSignal) { _, _ in
                followsLatest = true
                // Establish the final viewport before the bubble moves. An
                // animated scroll composed with the row lift reads as a second
                // send animation.
                scrollToBottom(scroller, animated: false)
            }
            .onChange(of: scrollRequest) { _, _ in
                scrollToBottom(scroller, animated: true)
            }
            .onAppear { scrollToBottom(scroller, animated: false) }
        }
    }

    @ViewBuilder
    private func transcriptRow(_ row: TranscriptRow, scroller: ScrollViewProxy) -> some View {
        switch row {
        case .olderHistory:
            // Older pages load themselves as the top scrolls into view,
            // matching the macOS transcript's near-top trigger.
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(height: 36)
            .onScrollVisibilityChange(threshold: 0.1) { visible in
                guard visible else { return }
                loadOlderHistory(scroller)
            }
        case .setup:
            SessionSetupView(phases: controller.setupPhases)
        case let .item(item, isActive):
            ConversationItemRow(item: item, isActive: isActive)
                .modifier(UserSendLiftModifier(
                    messageID: isUser(item) ? item.id : nil,
                    distance: sendLift,
                    request: controller.userSendAnimationRequest,
                    controller: controller,
                    reduceMotion: reduceMotion,
                    geometryReady: hasMeasuredContentTail && hasMeasuredComposerTop,
                ))
        case let .activity(kind):
            switch kind {
            case .loadingHistory:
                ChatActivityRow("Loading conversation…")
            case .startingAgent:
                Text("Starting agent…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .shimmering()
            case let .connecting(message):
                ChatActivityRow(message)
            case let .serverWait(message):
                ChatActivityRow(
                    message,
                    systemImage: "arrow.triangle.2.circlepath",
                    shimmers: true
                )
            }
        case let .sessionError(message):
            sessionErrorRow(message)
        case let .statusError(message):
            ChatErrorRow(
                message,
                actionTitle: "Retry",
                action: { Task { await controller.retry() } }
            )
        }
    }

    @ViewBuilder
    private func sessionErrorRow(_ message: String) -> some View {
        if controller.errorRequiresHarnessAuthentication {
            ChatErrorRow(
                message,
                actionTitle: "Open Settings",
                action: {
                    NotificationCenter.default.post(name: .codevisorOpenSettings, object: nil)
                }
            )
        } else {
            ChatErrorRow(
                message,
                actionTitle: "Retry",
                action: { Task { await controller.retrySessionFailure() } }
            )
        }
    }

    /// Fetches the next page of history and re-anchors the previously-topmost
    /// item to the top of the viewport, so the prepended rows land above the
    /// fold instead of shoving the visible content down (and so the sentinel
    /// scrolls out of view rather than chain-loading every page).
    private func loadOlderHistory(_ scroller: ScrollViewProxy) {
        guard let model, model.hasOlderHistory, !model.isLoadingOlderHistory else { return }
        let anchorId = model.settledConversation.first?.id
        Task {
            await model.loadOlderHistory()
            if let anchorId {
                scroller.scrollTo(anchorId, anchor: .top)
            }
        }
    }

    private func scrollToBottomIfFollowing(_ scroller: ScrollViewProxy) {
        guard followsLatest else { return }
        // Opening a chat JUMPS to the newest content; only changes that happen
        // while you're watching scroll there. History arriving on open used to
        // animate the scroll, so a chat visibly scrolled itself on entry.
        //
        // Decided here rather than from an `onChange` so it can't depend on the
        // order SwiftUI happens to invoke sibling change handlers in: the first
        // follow-scroll of this view's life is the opening one, full stop.
        let isOpening = !hasOpened
        if isOpening { hasOpened = true }
        scrollToBottom(scroller, animated: !isOpening)
    }

    private func scrollToBottom(_ scroller: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.snappy(duration: 0.25)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        } else {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }
}

/// One conversation item: a trailing user bubble or a linear assistant turn.
/// The linear rendering (text and tools in stream order) is the interim shape;
/// worked-section collapsing arrives with the full transcript port.
private struct ConversationItemRow: View {
    let item: ConversationItem
    let isActive: Bool

    var body: some View {
        switch item {
        case let .user(message):
            UserBubbleRow(text: message.text, attachments: message.attachments)
        case let .assistant(message):
            AssistantTurnBody(turn: message.turn, turnId: message.id)
        }
    }
}

/// The trailing user bubble, with its attachment thumbnails above it as on
/// macOS. Optimistic and settled messages both render through this one view
/// under the same client-generated row identity.
private struct UserBubbleRow: View {
    @Environment(\.theme) private var theme
    let text: String
    let attachments: [Attachment]

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 8) {
                if !attachments.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            AttachmentThumbnailView(attachment: attachment)
                        }
                    }
                }
                if !text.isEmpty {
                    Text(text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(theme.bubbleBackground, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
    }
}

/// The macOS assistant turn, ported: live "Working for Ns" sections that
/// stay open while streaming (chevron-less, like macOS), auto-collapse into
/// "Worked for Ns" when the turn ends, plan document between the planning
/// and implementation sections, recursive subagent sections, and the final
/// answer streaming below. Driven entirely by the turn's own state, so a
/// mid-stream turn loaded from history renders live too.
private struct AssistantTurnBody: View {
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.transcriptController) private var transcriptController
    @Environment(\.runningSubagentToolCallIds) private var runningSubagents
    @State private var textAnimationPresentation = StreamingTextAnimationPresentation()
    let turn: AssistantTurn
    /// Stable identity for the turn's disclosure keys (the message id).
    let turnId: UUID

    init(turn: AssistantTurn, turnId: UUID) {
        self.turn = turn
        self.turnId = turnId
    }

    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
    private var isGenerating: Bool { turn.isGenerating }

    /// A subagent that outlives its turn keeps the worked section open and
    /// its shimmer running, exactly like macOS.
    private var hasRunningSubagent: Bool {
        !runningSubagents.isDisjoint(with: turn.subagents.keys)
    }

    private var settled: Bool { !isGenerating && !hasRunningSubagent }
    @State private var hasActiveTextEntranceAnimation = false

    var body: some View {
        let _ = textAnimationPresentation.establishBaseline(
            settling: turn,
            turnID: turnId
        )
        VStack(alignment: .leading, spacing: 12) {
            workedSection(
                items: turn.workedItemsBeforePlan,
                key: .turn(turnId),
                showsTimer: turn.planBoundary == nil,
                allowsDeferred: true
            )
            if let planDocument = turn.planDocument {
                PlanDocumentView(markdown: planDocument)
            }
            // Deferred detail hydrates through the first section only; this
            // one appears once real post-plan items exist.
            workedSection(
                items: turn.workedItemsAfterPlan,
                key: .turnImplementation(turnId),
                showsTimer: true,
                allowsDeferred: false
            )
            if isGenerating, let retry = turn.retryStatus {
                ChatActivityRow(retryLabel(retry))
            } else if isGenerating, turn.showsActivityIndicator {
                if transcriptController?.isTakingLongerThanExpected == true {
                    ChatActivityRow(
                        transcriptController?.providerActivityPhase?.prolongedStatusMessage
                            ?? "Still waiting for the agent",
                        systemImage: "clock.badge.exclamationmark"
                    )
                } else if turn.isThinking {
                    ShimmeringText.thinking
                } else if !hasActiveTextEntranceAnimation {
                    // Commentary is not `finalText`, but its glyph fade is
                    // still visible activity and wins over this idle fallback.
                    ShimmeringText(text: "Waiting on harness...")
                }
            }
            if case let .text(entryID, markdown) = turn.finalText {
                StreamingMarkdownView(
                    markdown,
                    isComplete: !isGenerating,
                    streamID: TranscriptStreamingTextIdentity.main(
                        turnID: turnId,
                        entryID: entryID
                    ),
                    animationPresentation: textAnimationPresentation
                )
            }
            if let stopDetail = turn.stopDetail {
                turnErrorRow(stopDetail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(StreamingMarkdownEntranceAnimationPreferenceKey.self) { active in
            hasActiveTextEntranceAnimation = active
        }
        // The macOS auto-collapse: sections fold into their summary line the
        // moment the turn (and its last background subagent) finishes.
        .onChange(of: settled) { _, isSettled in
            guard isSettled else { return }
            store.setExpanded(.turn(turnId), false)
            store.setExpanded(.turnImplementation(turnId), false)
        }
    }

    @ViewBuilder
    private func turnErrorRow(_ message: String) -> some View {
        if let transcriptController,
           transcriptController.errorRequiresHarnessAuthentication,
           transcriptController.errorMessage == message {
            ChatErrorRow(
                message,
                actionTitle: "Open Settings",
                action: {
                    NotificationCenter.default.post(name: .codevisorOpenSettings, object: nil)
                }
            )
        } else if let transcriptController,
                  transcriptController.canRetryTurn(turnId) {
            ChatErrorRow(
                message,
                actionTitle: "Retry response",
                action: { Task { await transcriptController.retryTurn(turnId) } }
            )
        } else {
            ChatErrorRow(message)
        }
    }

    private func retryLabel(_ retry: RetryStatus) -> String {
        guard let attempt = retry.attempt, let of = retry.of else { return retry.message }
        return "\(retry.message) \(attempt)/\(of)"
    }

    /// One worked section: open with a live timer while streaming (not
    /// user-collapsible, as on macOS), a tappable "Worked for Ns" summary
    /// once settled.
    @ViewBuilder
    private func workedSection(
        items: [WorkedItem],
        key: TranscriptDisclosureStore.Key,
        showsTimer: Bool,
        allowsDeferred: Bool
    ) -> some View {
        if !items.isEmpty || (allowsDeferred && turn.hasDeferredWorkedDetails) {
            let isExpanded = store.isExpanded(key, default: !settled)
            // Spacing 0, on purpose: the reveal stays mounted at zero height
            // through the collapse animation, and a spaced VStack would keep
            // one spacing slot for it below the divider until the delayed
            // unmount — a visible jump after the animation settles (the same
            // bug the macOS disclosures once had). The gap above the revealed
            // content lives INSIDE the reveal instead, so it shrinks away
            // with the height.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    sectionLabel(showsTimer: showsTimer)
                        // One chrome size everywhere: the worked label, tool
                        // group headers, and subagent headers all sit at
                        // .callout, a notch under the body prose — the same
                        // relationship the macOS transcript has.
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if settled {
                        TranscriptDisclosureChevron(expanded: isExpanded)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard settled else { return }
                    store.toggle(key, default: !settled)
                }
                .padding(.bottom, 8)

                // As on macOS: the divider belongs to the disclosure header,
                // not its revealed contents, so a rendered Worked section
                // keeps the line collapsed and expanded alike.
                Divider()

                TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        if allowsDeferred, turn.hasDeferredWorkedDetails,
                           let itemId = turn.deferredDetailItemId,
                           let transcriptController {
                            DeferredWorkedDetails(controller: transcriptController, itemId: itemId)
                        } else {
                            TurnItemsView(
                                items: items,
                                turn: turn,
                                turnId: turnId,
                                depth: 0,
                                isTurnActive: isGenerating,
                                animationPresentation: textAnimationPresentation
                            )
                        }
                    }
                    .padding(.top, 10)
                }
            }
        }
    }

    /// "Working for 12s" (live) while streaming; "Planned" for the planning
    /// section once a plan boundary exists; "Worked for 12s" settled.
    @ViewBuilder
    private func sectionLabel(showsTimer: Bool) -> some View {
        if isGenerating, showsTimer {
            TimelineView(.periodic(from: turn.startedAt ?? Date(), by: 1)) { context in
                Text("Working for \(Self.format(elapsedSeconds(to: context.date)))")
            }
        } else if !showsTimer {
            Text("Planned")
        } else {
            Text(workedTitle)
        }
    }

    private var workedTitle: String {
        guard let duration = turn.duration, duration >= 1 else { return "Worked for a moment" }
        return "Worked for \(Self.format(Int(duration.rounded())))"
    }

    private func elapsedSeconds(to date: Date) -> Int {
        guard let started = turn.startedAt else { return 0 }
        return max(0, Int(date.timeIntervalSince(started)))
    }

    private static func format(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// The macOS TranscriptItemsView: worked items in stream order, recursing
/// into subagent sections.
private struct TurnItemsView: View {
    let items: [WorkedItem]
    let turn: AssistantTurn
    let turnId: UUID
    let depth: Int
    let isTurnActive: Bool
    let animationPresentation: StreamingTextAnimationPresentation
    var parentToolCallID: String? = nil

    private static let maxNestingDepth = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                switch item {
                case let .text(entryID, markdown):
                    StreamingMarkdownView(
                        markdown,
                        isComplete: !isTurnActive,
                        streamID: streamID(for: entryID),
                        animationPresentation: animationPresentation
                    )
                        .opacity(0.85)
                case let .toolGroup(_, calls):
                    ToolGroupView(
                        calls: calls,
                        isTurnActive: isTurnActive,
                        // Follow the work: the trailing group on the main
                        // thread opens itself while streaming.
                        autoExpanded: depth == 0 && isTurnActive
                            && (calls.last.map { turn.isTrailingToolGroup(lastToolCallId: $0.toolCallId) } ?? false)
                    )
                case let .subagent(_, call):
                    if depth + 1 < Self.maxNestingDepth {
                        SubagentSection(
                            call: call,
                            turn: turn,
                            turnId: turnId,
                            depth: depth,
                            isTurnActive: isTurnActive,
                            animationPresentation: animationPresentation
                        )
                    } else {
                        ToolCallRow(call: call, isTurnActive: isTurnActive)
                    }
                case let .contextCompaction(_, status):
                    switch status {
                    case .started:
                        ShimmeringText.compactingContext
                    case .completed:
                        AgentStatusText.contextCompacted
                    case .failed:
                        EmptyView()
                    }
                }
            }
        }
        // Ambient size for worked-section chrome that doesn't set its own
        // font (tool group headers, tool row titles): .callout, matching the
        // worked and subagent labels. Markdown commentary is unaffected — it
        // takes its sizes from the markdown theme.
        .font(.callout)
    }

    private func streamID(for entryID: String) -> String {
        if let parentToolCallID {
            return TranscriptStreamingTextIdentity.subagent(
                turnID: turnId,
                parentToolCallID: parentToolCallID,
                entryID: entryID
            )
        }
        return TranscriptStreamingTextIdentity.main(turnID: turnId, entryID: entryID)
    }
}

/// The macOS SubagentSectionView: a wand header shimmering while the
/// subagent runs, its transcript recursing beneath.
private struct SubagentSection: View {
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.runningSubagentToolCallIds) private var runningSubagents
    let call: ToolCall
    let turn: AssistantTurn
    let turnId: UUID
    let depth: Int
    let isTurnActive: Bool
    let animationPresentation: StreamingTextAnimationPresentation

    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
    private var key: TranscriptDisclosureStore.Key { .subagent(call.toolCallId) }

    private var isRunning: Bool {
        (isTurnActive && !call.isSettled) || runningSubagents.contains(call.toolCallId)
    }

    private var items: [WorkedItem] { turn.subagentItems(call.toolCallId) }

    var body: some View {
        let isExpanded = store.isExpanded(key, default: isRunning)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.sparkles")
                    // One notch under the callout label, like the tool group
                    // icon — the macOS transcript's icon-under-text ratio.
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(call.displayTitle(diffTotals: nil))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .shimmering(isRunning)
                if call.status == .failed {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TranscriptDisclosureChevron(expanded: isExpanded)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture {
                store.toggle(key, default: isRunning)
            }

            TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    TurnItemsView(
                        items: items,
                        turn: turn,
                        turnId: turnId,
                        depth: depth + 1,
                        isTurnActive: isTurnActive,
                        animationPresentation: animationPresentation,
                        parentToolCallID: call.toolCallId
                    )
                    if isRunning, items.isEmpty {
                        ShimmeringText.startingAgent
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 8)
            }
        }
        .onChange(of: isRunning) { _, running in
            if !running {
                store.setExpanded(key, false)
            }
        }
    }
}

/// Historical turns arrive without their worked detail; expanding the section
/// hydrates just that turn's bounded event set through the shared controller.
private struct DeferredWorkedDetails: View {
    let controller: SessionController
    let itemId: String
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                Button("Retry loading worked details") { failed = false }
                    .font(.footnote)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading worked details…")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .task {
                    if await !controller.loadTranscriptDetails(itemId) {
                        failed = true
                    }
                }
            }
        }
    }
}

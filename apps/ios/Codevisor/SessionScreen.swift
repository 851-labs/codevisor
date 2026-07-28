import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI

/// The chat pane body: connects an existing session through the shared
/// SessionController/SessionModel engine and renders the transcript with the
/// shared row views. Hosted by WorkspaceScreen, which owns the navigation
/// chrome; the VirtualTranscriptLayout-backed virtualizer replaces the scroll
/// host as Phase 4 completes.
struct SessionTranscriptView: View {
    @Bindable var controller: SessionController
    let serverConfig: CodevisorServerConfig?
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
    /// The macOS send animation: a sent message rides the scroll up to the
    /// top of the viewport, with the trailing spacer stretched so there's
    /// room for the response to stream in below it.
    @State private var awaitingSendScroll = false
    @State private var sendPinActive = false

    var body: some View {
        Group {
            if controller.model == nil, case let .failed(message) = controller.status {
                ContentUnavailableView {
                    Label("Couldn't Connect", systemImage: "bolt.slash")
                } description: {
                    Text(message)
                }
            } else {
                chat
            }
        }
        .onAppear {
            if attachmentImages == nil {
                attachmentImages = AttachmentImageStore { [weak controller] fileId in
                    guard let controller else { throw SessionControllerError.serverUnavailable }
                    return try await controller.fileData(id: fileId)
                }
            }
        }
        .environment(\.attachmentImages, attachmentImages)
    }

    /// The watermark shows while there's nothing to read: a model-less draft
    /// (new-worktree chats deliberately don't connect until first send) or an
    /// empty conversation.
    private var showsWatermark: Bool {
        guard controller.pendingUserText == nil, controller.setupPhases.isEmpty else { return false }
        guard let model = controller.model else { return true }
        return model.settledConversation.isEmpty && model.activeItem == nil
    }

    /// The first send, before a model exists: the optimistic user message
    /// with the live setup phases beneath it — worktree creation and agent
    /// start render in the chat history exactly like macOS.
    private var showsPendingSetup: Bool {
        controller.model == nil
            && (controller.pendingUserText != nil || !controller.setupPhases.isEmpty)
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
            if let model = controller.model {
                transcriptScroll(model)
            } else if showsPendingSetup {
                pendingSetupColumn
            }

            VStack(spacing: 8) {
                if controller.model == nil, case let .connecting(message) = controller.status {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(message)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if controller.model != nil, !isAtBottom {
                    HStack {
                        Spacer()
                        scrollToBottomButton
                    }
                }
                ComposerBar(
                    controller: controller,
                    maxHeight: availableHeight - 88,
                    collapsedHeight: $composerHeight
                )
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            availableHeight = height
        }
        // Tab snapshots crop the composer out so previews show only content.
        .onChange(of: composerHeight, initial: true) { _, height in
            PaneSnapshotCache.shared.activeBottomChrome = height + 6
        }
        .background(Color(.systemGroupedBackground))
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

    /// The model-less first send: optimistic user bubble, then either the
    /// setup phases or a "Starting agent…" shimmer until the first phase
    /// arrives.
    private var pendingSetupColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let text = controller.pendingUserText {
                    OptimisticUserRow(text: text, attachments: controller.pendingUserAttachments)
                }
                if controller.setupPhases.isEmpty {
                    Text("Starting agent…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .shimmering()
                } else {
                    SessionSetupView(phases: controller.setupPhases)
                }
                Color.clear.frame(height: composerHeight + 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func transcriptScroll(_ model: SessionModel) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if model.hasOlderHistory {
                    // Older pages load themselves as the top scrolls into
                    // view, matching the macOS transcript's near-top trigger.
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .frame(height: 36)
                    .onScrollVisibilityChange(threshold: 0.1) { visible in
                        guard visible else { return }
                        loadOlderHistory(model, scroller)
                    }
                }

                ForEach(model.settledConversation) { item in
                    ConversationItemRow(item: item, isActive: false)
                }
                if !controller.setupPhases.isEmpty {
                    SessionSetupView(phases: controller.setupPhases)
                }
                if let active = model.activeItem {
                    ConversationItemRow(item: active, isActive: true)
                }
                if controller.isLoadingInitialHistory {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }

                // Breathing room past the composer so the newest content can
                // clear it. While a send is pinned to the top (macOS-style),
                // the spacer stretches to nearly a viewport so the response
                // has room to stream in below the sent message.
                Color.clear
                    .frame(
                        height: sendPinActive
                            ? max(composerHeight + 24, viewportHeight - 140)
                            : composerHeight + 24
                    )
                    .id(Self.bottomAnchor)
                    .onScrollVisibilityChange(threshold: 0.05) { visible in
                        isAtBottom = visible
                        followsLatest = visible
                        if visible { sendPinActive = false }
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
        // The lazy stack's estimated row heights make the indicator grow and
        // shrink as content materializes; hide it until the virtualizer
        // provides stable content sizing.
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .environment(\.transcriptDisclosure, disclosure)
        .environment(\.transcriptController, controller)
        .environment(\.runningSubagentToolCallIds, controller.runningSubagentToolCallIds)
        // Streaming tokens, settled turns, and sends all re-pin while
        // following; a send always returns to the newest content.
        .onChange(of: model.activeItemRevision) { _, _ in
            scrollToBottomIfFollowing(scroller)
        }
        .onChange(of: model.settledConversation.count) { _, _ in
            if awaitingSendScroll {
                pinSentMessageToTop(model, scroller)
            } else {
                scrollToBottomIfFollowing(scroller)
            }
        }
        .onChange(of: controller.userSendSignal) { _, _ in
            awaitingSendScroll = true
            sendPinActive = true
            pinSentMessageToTop(model, scroller)
        }
        .onChange(of: scrollRequest) { _, _ in
            scrollToBottom(scroller, animated: true)
        }
        .onAppear { scrollToBottom(scroller, animated: false) }
        }
    }

    /// Fetches the next page of history and re-anchors the previously-topmost
    /// item to the top of the viewport, so the prepended rows land above the
    /// fold instead of shoving the visible content down (and so the sentinel
    /// scrolls out of view rather than chain-loading every page).
    private func loadOlderHistory(_ model: SessionModel, _ scroller: ScrollViewProxy) {
        guard model.hasOlderHistory, !model.isLoadingOlderHistory else { return }
        let anchorId = model.settledConversation.first?.id
        Task {
            await model.loadOlderHistory()
            if let anchorId {
                scroller.scrollTo(anchorId, anchor: .top)
            }
        }
    }

    /// The sent message animates from the composer up to the top of the
    /// viewport — the same motion as the macOS transcript's send handoff.
    private func pinSentMessageToTop(_ model: SessionModel, _ scroller: ScrollViewProxy) {
        guard case .user = model.settledConversation.last else { return }
        guard let id = model.settledConversation.last?.id else { return }
        awaitingSendScroll = false
        // The response streams in below the pinned message; following the
        // tail would immediately yank the view back down.
        followsLatest = false
        withAnimation(.snappy(duration: 0.45)) {
            scroller.scrollTo(id, anchor: .top)
        }
    }

    private func scrollToBottomIfFollowing(_ scroller: ScrollViewProxy) {
        guard followsLatest else { return }
        scrollToBottom(scroller, animated: true)
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
    @Environment(\.theme) private var theme
    let item: ConversationItem
    let isActive: Bool

    var body: some View {
        switch item {
        case let .user(message):
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.attachments.isEmpty {
                        // Thumbnails above the bubble, as on macOS.
                        HStack(spacing: 8) {
                            ForEach(message.attachments) { attachment in
                                AttachmentThumbnailView(attachment: attachment)
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(theme.bubbleBackground, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
            }
        case let .assistant(message):
            AssistantTurnBody(turn: message.turn, turnId: message.id)
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
    let turn: AssistantTurn
    /// Stable identity for the turn's disclosure keys (the message id).
    let turnId: UUID

    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
    private var isGenerating: Bool { turn.isGenerating }

    /// A subagent that outlives its turn keeps the worked section open and
    /// its shimmer running, exactly like macOS.
    private var hasRunningSubagent: Bool {
        !runningSubagents.isDisjoint(with: turn.subagents.keys)
    }

    private var settled: Bool { !isGenerating && !hasRunningSubagent }

    var body: some View {
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
            if isGenerating, turn.showsActivityIndicator {
                ShimmeringText.thinking
            }
            if case let .text(_, markdown) = turn.finalText {
                StreamingMarkdownView(markdown, isComplete: !isGenerating)
            }
            if let stopDetail = turn.stopDetail {
                Label(stopDetail, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The macOS auto-collapse: sections fold into their summary line the
        // moment the turn (and its last background subagent) finishes.
        .onChange(of: settled) { _, isSettled in
            guard isSettled else { return }
            store.setExpanded(.turn(turnId), false)
            store.setExpanded(.turnImplementation(turnId), false)
        }
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    sectionLabel(showsTimer: showsTimer)
                        .font(.subheadline)
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

                TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        if allowsDeferred, turn.hasDeferredWorkedDetails,
                           let itemId = turn.deferredDetailItemId,
                           let transcriptController {
                            DeferredWorkedDetails(controller: transcriptController, itemId: itemId)
                        } else {
                            TurnItemsView(items: items, turn: turn, depth: 0, isTurnActive: isGenerating)
                        }
                    }
                    .padding(.top, 2)
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
    let depth: Int
    let isTurnActive: Bool

    private static let maxNestingDepth = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                switch item {
                case let .text(_, markdown):
                    StreamingMarkdownView(markdown, isComplete: !isTurnActive)
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
                        SubagentSection(call: call, turn: turn, depth: depth, isTurnActive: isTurnActive)
                    } else {
                        ToolCallRow(call: call, isTurnActive: isTurnActive)
                    }
                case .contextCompaction:
                    AgentStatusText.contextCompacted
                }
            }
        }
    }
}

/// The macOS SubagentSectionView: a wand header shimmering while the
/// subagent runs, its transcript recursing beneath.
private struct SubagentSection: View {
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.runningSubagentToolCallIds) private var runningSubagents
    let call: ToolCall
    let turn: AssistantTurn
    let depth: Int
    let isTurnActive: Bool

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
                    .font(.callout)
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
                    TurnItemsView(items: items, turn: turn, depth: depth + 1, isTurnActive: isTurnActive)
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

/// The just-sent message, rendered before the server echoes it back — the
/// same trailing bubble as a settled user row.
private struct OptimisticUserRow: View {
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

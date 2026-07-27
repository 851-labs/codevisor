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
                if let question = controller.activeQuestion {
                    QuestionCardView(controller: controller, request: question)
                        .id(question.questionId)
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
            LazyVStack(alignment: .leading, spacing: 16) {
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
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .environment(\.transcriptDisclosure, disclosure)
        .environment(\.transcriptController, controller)
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
            AssistantTurnBody(turn: message.turn, isActive: isActive, turnId: message.id)
        }
    }
}

private struct AssistantTurnBody: View {
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.transcriptController) private var transcriptController
    let turn: AssistantTurn
    let isActive: Bool
    /// Stable identity for the turn's disclosure keys (the message id).
    let turnId: UUID

    private var isStreaming: Bool { isActive && turn.isGenerating }
    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isStreaming {
                // Stream in strict arrival order; text and tool groups must
                // never reorder around each other mid-turn.
                ForEach(turn.streamingItems) { item in
                    workedItemView(item, dimmed: false)
                }
            } else {
                workedSection(
                    items: turn.workedItemsBeforePlan,
                    key: .turn(turnId),
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
                    allowsDeferred: false
                )
                if case let .text(_, markdown) = turn.finalText {
                    StreamingMarkdownView(markdown)
                }
            }
            if isStreaming, let planDocument = turn.planDocument {
                PlanDocumentView(markdown: planDocument)
            }
            if isActive, turn.showsActivityIndicator {
                ShimmeringText.thinking
            }
            if let stopDetail = turn.stopDetail {
                Label(stopDetail, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A settled "Worked" disclosure: summary line collapsed, the full
    /// reasoning/tool trail on expand — the shared reveal machinery drives the
    /// animation exactly as on macOS.
    @ViewBuilder
    private func workedSection(
        items: [WorkedItem],
        key: TranscriptDisclosureStore.Key,
        allowsDeferred: Bool
    ) -> some View {
        if !items.isEmpty || (allowsDeferred && turn.hasDeferredWorkedDetails) {
            let isExpanded = store.isExpanded(key, default: false)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(workedLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TranscriptDisclosureChevron(expanded: isExpanded)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    store.toggle(key, default: false)
                }

                TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        if allowsDeferred, turn.hasDeferredWorkedDetails,
                           let itemId = turn.deferredDetailItemId,
                           let transcriptController {
                            DeferredWorkedDetails(controller: transcriptController, itemId: itemId)
                        } else {
                            ForEach(items) { item in
                                workedItemView(item, dimmed: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var workedLabel: String {
        if let duration = turn.duration, duration >= 1 {
            return "Worked for \(Self.durationFormatter.string(from: duration) ?? "a moment")"
        }
        return "Worked"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @ViewBuilder
    private func workedItemView(_ item: WorkedItem, dimmed: Bool) -> some View {
        switch item {
        case let .text(_, markdown):
            StreamingMarkdownView(markdown, isComplete: !isStreaming)
                .opacity(dimmed ? 0.85 : 1)
        case let .toolGroup(_, calls):
            ToolGroupView(calls: calls, isTurnActive: isStreaming)
        case let .subagent(_, call):
            ToolCallRow(call: call, isTurnActive: isStreaming)
        case .contextCompaction:
            AgentStatusText.contextCompacted
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

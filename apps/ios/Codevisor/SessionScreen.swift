import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import UIKit

extension Notification.Name {
    static let codevisorOpenSettings = Notification.Name("codevisor.open-settings")
}

/// The chat pane body: connects an existing session through the shared
/// SessionController/SessionModel engine and renders the transcript with the
/// shared row views. UIKit owns the virtual window and viewport coordinate so
/// opening, measurement, pagination, and streaming are one position system.
struct SessionTranscriptView: View {
    /// Increment whenever the iOS row-measurement environment changes. Scroll
    /// state can outlive a mounted transcript, so heights produced under an
    /// older hosting contract must not be restored as exact geometry.
    private static let transcriptMeasurementSchemaVersion = 1

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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.theme) private var theme
    @State private var disclosure = TranscriptDisclosureStore()
    /// The composer's resting height, used to size the transcript's bottom
    /// spacer and the mask that sits under the card.
    @State private var composerHeight: CGFloat = 96
    /// True while the transcript is parked at the newest content; drives both
    /// auto-scroll and the scroll-to-bottom button, mirroring the macOS
    /// transcript's follow mode.
    @State private var followsLatest = true
    @State private var isAtBottom = true
    /// Height available to the chat area, used to cap composer expansion.
    @State private var availableHeight: CGFloat = 600
    /// True while the composer is dragged to full height; the accessories
    /// around it (scroll-to-bottom, notice rails) hide until it collapses.
    @State private var composerExpanded = false
    /// Fetches and caches transcript attachment previews via the controller's
    /// authenticated client.
    @State private var attachmentImages: AttachmentImageStore?
    @State private var scrollCommand = TranscriptScrollCommand()
    @State private var historyLoadTask: Task<Void, Never>?
    @State private var showsInitialLoadingSpinner = false

    var body: some View {
        chat
            .onAppear { [controller] in
                followsLatest = controller.scrollState?.followMode.followsLatest ?? true
                isAtBottom = controller.scrollState?.isAtBottom ?? true
                if attachmentImages == nil {
                    attachmentImages = AttachmentImageStore { [weak controller] fileId in
                        guard let controller else {
                            throw SessionControllerError.serverUnavailable
                        }
                        return try await controller.fileData(id: fileId)
                    }
                }
                controller.transcriptViewDidAppear()
            }
            .onDisappear { [controller] in
                historyLoadTask?.cancel()
                historyLoadTask = nil
                controller.transcriptViewDidDisappear()
            }
            .environment(\.attachmentImages, attachmentImages)
            .task(id: isLoadingEmptyConversation) {
                showsInitialLoadingSpinner = false
                guard isLoadingEmptyConversation else { return }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, isLoadingEmptyConversation else { return }
                showsInitialLoadingSpinner = true
            }
    }

    private var isLoadingEmptyConversation: Bool {
        controller.isLoadingInitialHistory
            && controller.settledConversation.isEmpty
            && !controller.hasActiveItem
    }

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
        return controller.settledConversation.isEmpty && !controller.hasActiveItem
    }

    /// The scroll-to-bottom button only means something once there's a
    /// conversation to scroll through.
    private var hasScrollableContent: Bool {
        !controller.settledConversation.isEmpty || controller.hasActiveItem
    }

    // MARK: - The row list

    /// The whole chat as stable virtual rows. Plans are independent rows so a
    /// giant document is a virtualization boundary, matching macOS.
    private var transcriptRows: [TranscriptVirtualRow] {
        var rows: [TranscriptVirtualRow] = []
        let settled = controller.settledConversation
        let hasSetup = !controller.setupPhases.isEmpty
        let pendingMessage = controller.pendingUserMessage.flatMap { pending in
            settled.contains(where: { item in
                if case let .user(message) = item { return message.id == pending.id }
                return false
            }) ? nil : pending
        }
        let pendingIsOpeningRow = settled.isEmpty && !controller.hasActiveItem
        let waitingDescription = controller.waitingBackgroundTaskDescription
        let waitingAssistantID: UUID? = {
            guard !controller.hasActiveItem,
                  waitingDescription != nil,
                  case let .assistant(message)? = settled.last,
                  message.turn.finalText != nil else { return nil }
            return message.id
        }()

        // The opening block: the conversation hasn't landed yet. Covers the
        // first send (with or without a model) and an empty connected chat.
        if settled.isEmpty, !controller.hasActiveItem {
            if let message = pendingMessage {
                let showsStartingAgent = !hasSetup
                rows.append(.init(
                    id: .message(message.id),
                    content: .optimistic(
                        message,
                        showsStartingAgent: showsStartingAgent
                    ),
                    estimatedHeight: 90,
                    measurementRevision: Self.optimisticMeasurementRevision(
                        for: message,
                        showsStartingAgent: showsStartingAgent
                    )
                ))
            }
            if hasSetup {
                rows.append(.init(
                    id: .setup,
                    content: .setup(controller.setupPhases),
                    estimatedHeight: 80
                ))
            }
            // Initial history loading is an overlay, never transcript geometry.
            if !controller.isLoadingInitialHistory, pendingMessage == nil {
                if let message = controller.serverWaitMessage {
                    rows.append(.init(
                        id: .serverWait,
                        content: .serverWait(message),
                        estimatedHeight: 32
                    ))
                } else if case let .connecting(message) = controller.status {
                    rows.append(.init(
                        id: .connecting,
                        content: .connecting(message),
                        estimatedHeight: 32
                    ))
                }
            }
        }

        // Setup is anchored to the START of the conversation — the one time it
        // ran: ahead of a leading assistant turn, or right after the first user
        // message, whose send triggered it.
        for (index, item) in settled.enumerated() {
            if index == 0, hasSetup, isAssistant(item) {
                rows.append(.init(
                    id: .setup,
                    content: .setup(controller.setupPhases),
                    estimatedHeight: 80
                ))
            }
            appendSettled(
                item,
                waitingOnBackgroundTask: item.id == waitingAssistantID
                    ? waitingDescription
                    : nil,
                to: &rows
            )
            if index == 0, hasSetup, isUser(item) {
                rows.append(.init(
                    id: .setup,
                    content: .setup(controller.setupPhases),
                    estimatedHeight: 80
                ))
            }
        }

        if settled.isEmpty, controller.hasActiveItem, hasSetup {
            rows.append(.init(
                id: .setup,
                content: .setup(controller.setupPhases),
                estimatedHeight: 80
            ))
        }
        if controller.hasActiveItem {
            rows.append(.init(id: .active, content: .active, estimatedHeight: 320))
        }
        if !pendingIsOpeningRow, let message = pendingMessage {
            rows.append(.init(
                id: .message(message.id),
                content: .optimistic(message, showsStartingAgent: false),
                estimatedHeight: 90,
                measurementRevision: Self.optimisticMeasurementRevision(
                    for: message,
                    showsStartingAgent: false
                )
            ))
        }

        if let waitingDescription, waitingAssistantID == nil, !controller.hasActiveItem {
            rows.append(.init(
                id: .backgroundTask,
                content: .backgroundTask(waitingDescription),
                estimatedHeight: 32
            ))
        }
        if let updatingHarnessName = controller.waitingHarnessUpdateName {
            rows.append(.init(
                id: .updateGate,
                content: .updateGate(updatingHarnessName),
                estimatedHeight: 32
            ))
        }

        if !settled.isEmpty || controller.hasActiveItem {
            if let message = controller.serverWaitMessage {
                rows.append(.init(
                    id: .serverWait,
                    content: .serverWait(message),
                    estimatedHeight: 32
                ))
            }
        }

        if let message = controller.sessionErrorMessage {
            rows.append(.init(id: .error, content: .error(message), estimatedHeight: 56))
        }
        if case let .failed(message) = controller.status, message != controller.sessionErrorMessage {
            rows.append(.init(
                id: .statusError,
                content: .error(message),
                estimatedHeight: 56
            ))
        }
        rows.append(.init(
            id: .bottomSpacer,
            content: .bottomSpacer(max(1, composerHeight + 24)),
            estimatedHeight: max(1, composerHeight + 24)
        ))
        return rows
    }

    private func appendSettled(
        _ item: ConversationItem,
        waitingOnBackgroundTask: String?,
        to rows: inout [TranscriptVirtualRow]
    ) {
        guard case let .assistant(message) = item,
              let planDocument = message.turn.planDocument,
              !planDocument.isEmpty else {
            rows.append(.init(
                id: .message(item.id),
                content: .message(
                    item,
                    waitingOnBackgroundTask: waitingOnBackgroundTask
                ),
                estimatedHeight: Self.estimatedHeight(for: item),
                measurementRevision: Self.measurementRevision(
                    for: item,
                    waitingOnBackgroundTask: waitingOnBackgroundTask
                )
            ))
            return
        }

        let revision = Self.measurementRevision(
            for: item,
            waitingOnBackgroundTask: waitingOnBackgroundTask
        )
        if message.turn.hasDeferredWorkedDetails
            || !message.turn.workedItemsBeforePlan.isEmpty {
            rows.append(.init(
                id: .assistantPlanning(message.id),
                content: .assistantPlanning(message),
                estimatedHeight: 44,
                measurementRevision: revision
            ))
        }
        rows.append(.init(
            id: .plan(message.id),
            content: .planDocument(planDocument),
            estimatedHeight: Self.estimatedPlanHeight(planDocument),
            measurementRevision: Self.planMeasurementRevision(planDocument)
        ))
        if !message.turn.workedItemsAfterPlan.isEmpty
            || message.turn.finalText != nil
            || message.turn.stopDetail != nil
            || message.turn.isGenerating {
            rows.append(.init(
                id: .assistantResult(message.id),
                content: .assistantResult(
                    message,
                    waitingOnBackgroundTask: waitingOnBackgroundTask
                ),
                estimatedHeight: 240,
                measurementRevision: revision
            ))
        }
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
            // One always-mounted native transcript for every connection state.
            transcript

            if showsInitialLoadingSpinner, isLoadingEmptyConversation {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.bottom, composerHeight)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Loading conversation")
            }

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
            scrollCommand.token &+= 1
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

    private func isUser(_ item: ConversationItem) -> Bool {
        if case .user = item { return true }
        return false
    }

    private func isAssistant(_ item: ConversationItem) -> Bool {
        if case .assistant = item { return true }
        return false
    }

    // MARK: - Native transcript

    private var transcript: some View {
        let rows = transcriptRows
        return NativeTranscriptView(
            rows: rows,
            initialState: controller.scrollState,
            followsLatest: followsLatest,
            hasOlderHistory: controller.hasOlderHistory,
            layoutFingerprint: transcriptLayoutFingerprint,
            scrollCommand: scrollCommand,
            sendAnimationRequest: controller.userSendAnimationRequest,
            reduceMotion: reduceMotion,
            claimSendAnimation: { request in
                controller.claimUserSendAnimation(request)
            },
            rowContent: { row in
                AnyView(
                    virtualRowContent(row)
                        .environment(\.theme, theme)
                        .environment(\.attachmentImages, attachmentImages)
                        .environment(\.transcriptDisclosure, disclosure)
                        .environment(\.transcriptController, controller)
                        .environment(
                            \.runningSubagentToolCallIds,
                            controller.runningSubagentToolCallIds
                        )
                        .environment(\.markdownTableBleed, 16)
                )
            },
            onViewportChange: { state in
                controller.scrollState = state
            },
            onBottomStateChange: { atBottom in
                DispatchQueue.main.async {
                    if isAtBottom != atBottom { isAtBottom = atBottom }
                }
            },
            onFollowStateChange: { follows in
                DispatchQueue.main.async {
                    if followsLatest != follows { followsLatest = follows }
                }
            },
            onNearTop: {
                Task { @MainActor in requestOlderHistoryLoad() }
            }
        )
        // Match SwiftUI.ScrollView's navigation behavior: the scroll surface
        // reaches beneath the translucent top bar, while its UIKit content
        // inset keeps the first resting row below that chrome.
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: controller.userSendSignal) { _, _ in
            followsLatest = true
            scrollCommand.token &+= 1
        }
    }

    @ViewBuilder
    private func virtualRowContent(_ row: TranscriptVirtualRow) -> some View {
        switch row.content {
        case let .message(item, waitingOnBackgroundTask):
            ConversationItemRow(
                item: item,
                isWaitingOnUser: controller.pendingQuestion != nil,
                waitingOnBackgroundTask: waitingOnBackgroundTask
            )
        case let .assistantPlanning(message):
            AssistantTurnBody(
                turn: message.turn,
                turnId: message.id,
                isWaitingOnUser: controller.pendingQuestion != nil,
                presentation: .planning
            )
        case let .planDocument(markdown):
            PlanDocumentView(markdown: markdown)
        case let .assistantResult(message, waitingOnBackgroundTask):
            AssistantTurnBody(
                turn: message.turn,
                turnId: message.id,
                isWaitingOnUser: controller.pendingQuestion != nil,
                waitingOnBackgroundTask: waitingOnBackgroundTask,
                presentation: .result
            )
        case .active:
            TranscriptActiveItemView(controller: controller)
        case let .setup(phases):
            SessionSetupView(phases: phases)
        case let .optimistic(message, showsStartingAgent):
            if !message.text.isEmpty || !message.attachments.isEmpty {
                UserBubbleRow(text: message.text, attachments: message.attachments)
                if showsStartingAgent {
                    ShimmeringText.startingAgent
                }
            }
        case let .backgroundTask(description):
            ChatActivityRow(
                "Waiting on \(description)...",
                systemImage: "clock.arrow.circlepath",
                shimmers: true
            )
        case let .updateGate(harnessName):
            ChatActivityRow(
                "Waiting for \(harnessName) to finish updating...",
                systemImage: "arrow.down.circle",
                shimmers: true
            )
        case let .connecting(message):
            ChatActivityRow(message)
        case let .serverWait(message):
            ChatActivityRow(
                message,
                systemImage: "arrow.triangle.2.circlepath",
                shimmers: true
            )
        case let .error(message):
            if row.id == .statusError {
                ChatErrorRow(
                    message,
                    actionTitle: "Retry",
                    action: { Task { await controller.retry() } }
                )
            } else {
                sessionErrorRow(message)
            }
        case let .bottomSpacer(height):
            Color.clear.frame(height: height)
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

    private func requestOlderHistoryLoad() {
        guard historyLoadTask == nil, controller.hasOlderHistory,
              !controller.isLoadingOlderHistory else { return }
        historyLoadTask = Task { @MainActor in
            defer { historyLoadTask = nil }
            await controller.loadOlderHistory()
        }
    }

    private var transcriptLayoutFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(dynamicTypeSize)
        hasher.combine(Self.transcriptMeasurementSchemaVersion)
        return hasher.finalize()
    }

    private static func estimatedHeight(for item: ConversationItem) -> CGFloat {
        switch item {
        case let .user(message):
            max(52, min(240, 48 + CGFloat(message.text.count / 72) * 18))
        case .assistant:
            320
        }
    }

    private static func estimatedPlanHeight(_ markdown: String) -> CGFloat {
        max(120, min(640, 72 + CGFloat(markdown.utf8.count / 72) * 18))
    }

    private static func planMeasurementRevision(_ markdown: String) -> Int {
        var hasher = Hasher()
        hasher.combine(markdown.utf8.count)
        return hasher.finalize()
    }

    private static func optimisticMeasurementRevision(
        for message: UserMessage,
        showsStartingAgent: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(2)
        hasher.combine(message.text.utf8.count)
        hasher.combine(message.attachments.count)
        for attachment in message.attachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.sizeBytes)
        }
        hasher.combine(showsStartingAgent)
        return hasher.finalize()
    }

    private static func measurementRevision(
        for item: ConversationItem,
        waitingOnBackgroundTask: String?
    ) -> Int {
        var hasher = Hasher()
        switch item {
        case let .user(message):
            hasher.combine(0)
            hasher.combine(message.text.utf8.count)
            hasher.combine(message.attachments.count)
            for attachment in message.attachments {
                hasher.combine(attachment.id)
                hasher.combine(attachment.sizeBytes)
            }
        case let .assistant(message):
            let turn = message.turn
            hasher.combine(1)
            hasher.combine(turn.entries.count)
            hasher.combine(turn.isGenerating)
            hasher.combine(turn.detailRevision)
            hasher.combine(turn.hasDeferredWorkedDetails)
            hasher.combine(turn.contextCompactionStatus?.rawValue)
            hasher.combine(turn.planDocument?.utf8.count ?? 0)
            hasher.combine(turn.stopDetail?.utf8.count ?? 0)
            hasher.combine(turn.subagentActivityFingerprint)
        }
        hasher.combine(waitingOnBackgroundTask)
        return hasher.finalize()
    }
}

/// The only transcript subtree that observes token-level active-item changes.
/// Its host asks the native virtualizer to remeasure without rebuilding the
/// settled row list.
private struct TranscriptActiveItemView: View {
    let controller: SessionController
    @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement

    var body: some View {
        let revision = controller.activeItemRevision
        let waitingOnBackgroundTask = controller.waitingBackgroundTaskDescription
        let goal = controller.model?.goal
        let goalActivity = goal?.status == .active ? goal?.activity : nil
        if let item = controller.activeItem {
            ConversationItemRow(
                item: item,
                isWaitingOnUser: controller.pendingQuestion != nil,
                waitingOnBackgroundTask: waitingOnBackgroundTask,
                goalActivity: goalActivity
            )
                .environment(
                    \.runningSubagentToolCallIds,
                    controller.runningSubagentToolCallIds
                )
                .id(item.id)
                .onChange(of: revision, initial: true) { _, _ in
                    invalidateRowMeasurement?()
                }
                .onChange(of: waitingOnBackgroundTask) { _, _ in
                    invalidateRowMeasurement?()
                }
                .onChange(of: goalActivity) { _, _ in
                    invalidateRowMeasurement?()
                }
        }
    }
}

/// One conversation item: a trailing user bubble or a complete assistant turn.
private struct ConversationItemRow: View {
    let item: ConversationItem
    var isWaitingOnUser = false
    var waitingOnBackgroundTask: String? = nil
    var goalActivity: GoalActivity? = nil

    var body: some View {
        switch item {
        case let .user(message):
            UserBubbleRow(text: message.text, attachments: message.attachments)
        case let .assistant(message):
            AssistantTurnBody(
                turn: message.turn,
                turnId: message.id,
                isWaitingOnUser: isWaitingOnUser,
                waitingOnBackgroundTask: waitingOnBackgroundTask,
                goalActivity: goalActivity,
                presentation: .complete
            )
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
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                AttachmentThumbnailView(attachment: attachment)
                            }
                        }
                    }
                    .defaultScrollAnchor(.trailing)
                    .scrollBounceBehavior(.basedOnSize)
                }
                if !text.isEmpty {
                    SelectableTextView(
                        attributedText: NSAttributedString(
                            string: text,
                            attributes: [
                                .font: UIFont.preferredFont(forTextStyle: .body),
                                .foregroundColor: UIColor(theme.textPrimary),
                            ]
                        ),
                        fillsWidth: false
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        theme.bubbleBackground,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    MessageCopyButton(text: text, help: "Copy message")
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
private enum AssistantTurnPresentation {
    case complete
    case planning
    case result

    var showsPlanning: Bool { self != .result }
    var showsPlanDocument: Bool { self == .complete }
    var showsResult: Bool { self != .planning }
}

private struct AssistantTurnBody: View {
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.transcriptController) private var transcriptController
    @Environment(\.runningSubagentToolCallIds) private var runningSubagents
    @Environment(\.transcriptPerformAnchoredDisclosureChange)
    private var performAnchoredDisclosureChange
    @Environment(\.transcriptInvalidateRowMeasurement)
    private var invalidateRowMeasurement
    @State private var textAnimationPresentation = StreamingTextAnimationPresentation()
    @State private var hasAutoCollapsed: Bool
    let turn: AssistantTurn
    /// Stable identity for the turn's disclosure keys (the message id).
    let turnId: UUID
    let isWaitingOnUser: Bool
    let waitingOnBackgroundTask: String?
    let goalActivity: GoalActivity?
    let presentation: AssistantTurnPresentation

    init(
        turn: AssistantTurn,
        turnId: UUID,
        isWaitingOnUser: Bool = false,
        waitingOnBackgroundTask: String? = nil,
        goalActivity: GoalActivity? = nil,
        presentation: AssistantTurnPresentation = .complete
    ) {
        self.turn = turn
        self.turnId = turnId
        self.isWaitingOnUser = isWaitingOnUser
        self.waitingOnBackgroundTask = waitingOnBackgroundTask
        self.goalActivity = goalActivity
        self.presentation = presentation
        _hasAutoCollapsed = State(initialValue: turn.isGenerating && turn.finalTextIsAsserted)
    }

    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
    private var isGenerating: Bool { turn.isGenerating }

    private var sectionKeys: [TranscriptDisclosureStore.Key] {
        switch presentation {
        case .complete: [.turn(turnId), .turnImplementation(turnId)]
        case .planning: [.turn(turnId)]
        case .result: [.turnImplementation(turnId)]
        }
    }

    private func isExpanded(_ key: TranscriptDisclosureStore.Key) -> Bool {
        store.isExpanded(key, default: !settled)
    }

    /// A subagent that outlives its turn keeps the worked section open and
    /// its shimmer running, exactly like macOS.
    private var hasRunningSubagent: Bool {
        !runningSubagents.isDisjoint(with: turn.subagents.keys)
    }

    private var settled: Bool {
        (!isGenerating || turn.finalTextIsAsserted) && !hasRunningSubagent
    }
    @State private var hasActiveTextEntranceAnimation = false

    var body: some View {
        let _ = textAnimationPresentation.establishBaseline(
            settling: turn,
            turnID: turnId
        )
        let finalText = turn.finalText
        let postResponseGoalActivity = finalText == nil ? nil : goalActivity
        VStack(alignment: .leading, spacing: 14) {
            if presentation.showsPlanning {
                workedSection(
                    items: turn.workedItemsBeforePlan,
                    key: .turn(turnId),
                    showsTimer: turn.planBoundary == nil,
                    allowsDeferred: true
                )
            }
            if presentation.showsPlanDocument, let planDocument = turn.planDocument {
                PlanDocumentView(markdown: planDocument)
            }
            if presentation.showsResult {
                // Deferred detail hydrates through the first section only;
                // this row begins with post-plan implementation work.
                workedSection(
                    items: turn.workedItemsAfterPlan,
                    key: .turnImplementation(turnId),
                    showsTimer: true,
                    allowsDeferred: false
                )
                if !isWaitingOnUser, isGenerating, let retry = turn.retryStatus {
                    ChatActivityRow(retryLabel(retry))
                } else if postResponseGoalActivity == nil,
                          !isWaitingOnUser,
                          turn.showsActivityIndicator,
                          turn.contextCompactionStatus != .started {
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
                        // still visible activity and wins over this fallback.
                        ShimmeringText(text: "Waiting on harness...")
                    }
                }
                if case let .text(entryID, markdown) = finalText {
                    StreamingMarkdownView(
                        markdown,
                        isComplete: !isGenerating,
                        streamID: TranscriptStreamingTextIdentity.main(
                            turnID: turnId,
                            entryID: entryID
                        ),
                        animationPresentation: textAnimationPresentation
                    )
                    if let waitingOnBackgroundTask {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            ShimmeringText.waitingOnBackgroundTask(waitingOnBackgroundTask)
                            Spacer(minLength: 0)
                        }
                    }
                    if !isGenerating {
                        MessageCopyButton(text: markdown, help: "Copy response")
                    }
                }
                if !isWaitingOnUser, let postResponseGoalActivity {
                    ShimmeringText(text: goalActivityLabel(postResponseGoalActivity))
                }
                if !isGenerating, let stopDetail = turn.stopDetail {
                    turnErrorRow(stopDetail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(StreamingMarkdownEntranceAnimationPreferenceKey.self) { active in
            hasActiveTextEntranceAnimation = active
        }
        .onChange(of: isGenerating) { _, generating in
            if generating {
                if !hasAutoCollapsed {
                    for key in sectionKeys { store.setExpanded(key, true) }
                    invalidateRowMeasurement?()
                }
                return
            }
            autoCollapse()
        }
        .onChange(of: turn.finalTextIsAsserted) { _, asserted in
            if asserted, isGenerating { autoCollapse() }
        }
        .onChange(of: hasRunningSubagent) { _, running in
            if !running, !isGenerating { autoCollapse() }
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

    private func goalActivityLabel(_ activity: GoalActivity) -> String {
        switch activity {
        case .planning: "Planning…"
        case .verifying: "Verifying…"
        }
    }

    private func autoCollapse() {
        guard !hasAutoCollapsed, !hasRunningSubagent else { return }
        hasAutoCollapsed = true
        for key in sectionKeys { store.setExpanded(key, false) }
        invalidateRowMeasurement?()
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
            let isExpanded = isExpanded(key)
            VStack(alignment: .leading, spacing: 12) {
                if isGenerating, !hasAutoCollapsed {
                    workedHeader(
                        label: sectionLabel(showsTimer: showsTimer),
                        showsChevron: false,
                        expanded: isExpanded
                    )
                } else {
                    Button {
                        let change = {
                            if isExpanded {
                                store.setExpanded(key, false)
                            } else {
                                store.requestReveal(key)
                                store.setExpanded(key, true)
                            }
                            invalidateRowMeasurement?()
                        }
                        performAnchoredDisclosureChange?(change) ?? change()
                    } label: {
                        workedHeader(
                            label: sectionLabel(showsTimer: showsTimer),
                            showsChevron: true,
                            expanded: isExpanded
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // As on macOS: the divider belongs to the disclosure header,
                // not its revealed contents, so a rendered Worked section
                // keeps the line collapsed and expanded alike.
                Divider()

                if isExpanded {
                    WorkedContentReveal(key: key, store: store) {
                        VStack(alignment: .leading, spacing: 12) {
                            if allowsDeferred, turn.hasDeferredWorkedDetails,
                               let itemId = turn.deferredDetailItemId,
                               let transcriptController {
                                DeferredWorkedDetails(
                                    controller: transcriptController,
                                    itemId: itemId
                                )
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
                    }
                }
            }
        }
    }

    private func workedHeader(label: some View, showsChevron: Bool, expanded: Bool) -> some View {
        HStack(spacing: 6) {
            label
            if showsChevron {
                TranscriptDisclosureChevron(expanded: expanded)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .transaction { transaction in
            transaction.animation = nil
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

private struct WorkedContentReveal<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let key: TranscriptDisclosureStore.Key
    let store: TranscriptDisclosureStore
    let revealGeneration: Int
    @State private var isVisible: Bool
    private let content: Content

    init(
        key: TranscriptDisclosureStore.Key,
        store: TranscriptDisclosureStore,
        @ViewBuilder content: () -> Content
    ) {
        self.key = key
        self.store = store
        let generation = store.revealGeneration(for: key)
        revealGeneration = generation
        _isVisible = State(
            initialValue: !store.hasUnclaimedReveal(key, generation: generation)
        )
        self.content = content()
    }

    var body: some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : -8)
            .onAppear {
                let shouldAnimate = store.claimReveal(key, generation: revealGeneration)
                guard shouldAnimate, !reduceMotion else {
                    isVisible = true
                    return
                }
                withAnimation(Motion.entrance()) {
                    isVisible = true
                }
            }
    }
}

/// The macOS TranscriptItemsView: worked items in stream order, recursing
/// into subagent sections.
private struct TurnItemsView: View {
    @Environment(\.theme) private var theme
    let items: [WorkedItem]
    let turn: AssistantTurn
    let turnId: UUID
    let depth: Int
    let isTurnActive: Bool
    let animationPresentation: StreamingTextAnimationPresentation
    var parentToolCallID: String? = nil

    private static let maxNestingDepth = 3

    var body: some View {
        let trailingToolCallIds = depth == 0 && isTurnActive ? turn.trailingToolCallIds : []
        ForEach(items) { item in
            switch item {
            case let .text(entryID, markdown):
                StreamingMarkdownView(
                    markdown,
                    isComplete: !isTurnActive,
                    foregroundColor: theme.textSecondary,
                    streamID: streamID(for: entryID),
                    animationPresentation: animationPresentation
                )
            case let .toolGroup(_, calls):
                ToolGroupView(
                    calls: calls,
                    isTurnActive: isTurnActive,
                    autoExpanded: depth == 0 && isTurnActive
                        && (calls.last.map { trailingToolCallIds.contains($0.toolCallId) } ?? false)
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
    @Environment(\.theme) private var theme
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.runningSubagentToolCallIds) private var runningSubagents
    @Environment(\.transcriptPerformAnchoredDisclosureChange)
    private var performAnchoredDisclosureChange
    @State private var hasAutoCollapsed = false
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
    private var transcript: SubagentTranscript? { turn.subagents[call.toolCallId] }

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
                Text(call.displayTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shimmering(isRunning)
                statusGlyph
                TranscriptDisclosureChevron(expanded: isExpanded)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture {
                let change = { store.toggle(key, default: isRunning) }
                performAnchoredDisclosureChange?(change) ?? change()
            }

            TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    TurnItemsView(
                        items: items,
                        turn: turn,
                        turnId: turnId,
                        depth: depth + 1,
                        isTurnActive: isTurnActive,
                        animationPresentation: animationPresentation,
                        parentToolCallID: call.toolCallId
                    )
                    if isRunning, transcript?.isThinking == true {
                        ShimmeringText.thinking
                    } else if isRunning, items.isEmpty {
                        ShimmeringText.startingAgent
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 8)
            }
        }
        .onChange(of: isRunning) { _, running in
            if !running, !hasAutoCollapsed {
                hasAutoCollapsed = true
                store.setExpanded(key, false)
            }
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch call.status {
        case .failed:
            Image(systemName: "xmark.circle")
                .font(.caption)
                .foregroundStyle(theme.statusError)
        case .cancelled:
            Image(systemName: "slash.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
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
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading worked details…")
                        .foregroundStyle(.secondary)
                }
                .task {
                    if await !controller.loadTranscriptDetails(itemId) {
                        failed = true
                    }
                }
            }
        }
        .font(.callout)
    }
}

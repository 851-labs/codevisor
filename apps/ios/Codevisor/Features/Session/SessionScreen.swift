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
    private static let transcriptMeasurementSchemaVersion = 3

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
    /// During first-send promotion the destination beneath the sheet is laid
    /// out ahead of time, but the sheet remains the sole owner of presentation
    /// events and shared viewport state until the handoff commits.
    var presentationRole: TranscriptPresentationRole = .foreground
    var onSendAnimationCompleted: ((UserSendAnimationRequest) -> Void)? = nil
    var onSendAnimationStarted:
        (
            (
                UserSendAnimationRequest,
                TranscriptSendAnimationTarget
            ) -> Bool
        )? = nil
    var onComposerWillSend: ((String, CGRect) -> Void)? = nil
    /// A promoted New Chat keeps its UIKit editor first responder while its
    /// real workspace route mounts underneath. Ordinary chats still dismiss
    /// the keyboard on send.
    var preservesComposerFocusOnSend = false
    var composerTextEditorHandoffRole: ComposerTextEditorHandoffRole = .none
    var composerTextEditorHandoffID: UUID? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
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
    @State private var olderHistoryPresentation = TranscriptPaginationPresentationGate()
    @State private var showsInitialLoadingSpinner = false
    @State private var projectedRows: [TranscriptVirtualRow] = []
    @State private var projectedSessionID: UUID?
    @State private var isPreparingTranscript = true
    @State private var ownsVisibleTranscriptLifecycle = false
    /// Window-space bounds of the live editor. UIKit uses this as the actual
    /// launch point for the optimistic user row instead of estimating from the
    /// transcript's bottom inset.
    @State private var sendAnimationSourceFrame: CGRect?

    var body: some View {
        chat
            .onAppear { [controller] in
                followsLatest = controller.scrollState?.followMode.followsLatest ?? true
                isAtBottom = controller.scrollState?.isAtBottom ?? true
                installAttachmentImageStoreIfNeeded()
                updateVisibleTranscriptLifecycle(for: presentationRole)
            }
            .onChange(of: controller.previewCacheNamespace) {
                installAttachmentImageStoreIfNeeded()
            }
            .onChange(of: presentationRole) { _, role in
                updateVisibleTranscriptLifecycle(for: role)
            }
            .onDisappear { [controller] in
                historyLoadTask?.cancel()
                historyLoadTask = nil
                olderHistoryPresentation.cancel()
                if ownsVisibleTranscriptLifecycle {
                    ownsVisibleTranscriptLifecycle = false
                    controller.transcriptViewDidDisappear()
                }
            }
            .environment(\.attachmentImages, attachmentImages)
            .task(id: transcriptProjectionRequest) {
                let request = transcriptProjectionRequest
                let key = request.key
                let input = controller.transcriptProjectionInput
                if projectedSessionID != key.sessionID {
                    projectedRows = []
                    projectedSessionID = key.sessionID
                    isPreparingTranscript = true
                }
                do {
                    let rows = try await TranscriptRowProjectionCache.shared.rows(
                        for: key,
                        input: input,
                        options: request.options
                    )
                    guard !Task.isCancelled,
                        transcriptProjectionRequest == request
                    else { return }
                    projectedRows = rows
                    // The empty/loading snapshot is only a placeholder. Keep
                    // the native transcript parked until the projection that
                    // follows initial history hydration has arrived, otherwise
                    // its estimated row frames can reach the first visible
                    // paint before exact measurements collapse them.
                    isPreparingTranscript = input.isLoadingInitialHistory
                } catch is CancellationError {
                    return
                } catch {
                    isPreparingTranscript = false
                }
            }
            .task(id: isLoadingTranscriptContent) {
                showsInitialLoadingSpinner = false
                guard isLoadingTranscriptContent else { return }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, isLoadingTranscriptContent else { return }
                showsInitialLoadingSpinner = true
            }
    }

    private var isLoadingTranscriptContent: Bool {
        (isPreparingTranscript && projectedRows.isEmpty)
            || (controller.isLoadingInitialHistory
                && controller.settledConversation.isEmpty
                && !controller.hasActiveItem)
    }

    private func installAttachmentImageStoreIfNeeded() {
        let namespace = controller.previewCacheNamespace
        guard attachmentImages?.namespace != namespace else { return }
        attachmentImages = AttachmentImageStore(
            namespace: namespace,
            fetch: { [weak controller] source in
                guard let controller else {
                    throw SessionControllerError.serverUnavailable
                }
                return try await controller.fileData(for: source)
            },
            version: { [weak controller] source in
                guard let controller else {
                    throw SessionControllerError.serverUnavailable
                }
                return try await controller.fileVersion(for: source)
            }
        )
    }

    private func updateVisibleTranscriptLifecycle(for role: TranscriptPresentationRole) {
        let shouldOwnLifecycle = role == .foreground
        guard shouldOwnLifecycle != ownsVisibleTranscriptLifecycle else { return }
        ownsVisibleTranscriptLifecycle = shouldOwnLifecycle
        if shouldOwnLifecycle {
            controller.transcriptViewDidAppear()
        } else {
            controller.transcriptViewDidDisappear()
        }
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
                message.turn.finalText != nil
            else { return nil }
            return message.id
        }()

        // The opening block: the conversation hasn't landed yet. Covers the
        // first send (with or without a model) and an empty connected chat.
        if settled.isEmpty, !controller.hasActiveItem {
            if let message = pendingMessage {
                let showsStartingAgent = !hasSetup
                rows.append(
                    .init(
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
                rows.append(
                    .init(
                        id: .setup,
                        content: .setup(controller.setupPhases),
                        estimatedHeight: 80
                    ))
            }
            // Initial history loading is an overlay, never transcript geometry.
            if !controller.isLoadingInitialHistory, pendingMessage == nil {
                if let message = controller.serverWaitMessage {
                    rows.append(
                        .init(
                            id: .serverWait,
                            content: .serverWait(message),
                            estimatedHeight: 32
                        ))
                } else if case let .connecting(message) = controller.status {
                    rows.append(
                        .init(
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
                rows.append(
                    .init(
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
                rows.append(
                    .init(
                        id: .setup,
                        content: .setup(controller.setupPhases),
                        estimatedHeight: 80
                    ))
            }
        }

        if settled.isEmpty, controller.hasActiveItem, hasSetup {
            rows.append(
                .init(
                    id: .setup,
                    content: .setup(controller.setupPhases),
                    estimatedHeight: 80
                ))
        }
        if controller.hasActiveItem {
            rows.append(.init(id: .active, content: .active, estimatedHeight: 320))
        }
        if !pendingIsOpeningRow, let message = pendingMessage {
            rows.append(
                .init(
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
            rows.append(
                .init(
                    id: .backgroundTask,
                    content: .backgroundTask(waitingDescription),
                    estimatedHeight: 32
                ))
        }
        if let updatingHarnessName = controller.waitingHarnessUpdateName {
            rows.append(
                .init(
                    id: .updateGate,
                    content: .updateGate(updatingHarnessName),
                    estimatedHeight: 32
                ))
        }

        if !settled.isEmpty || controller.hasActiveItem {
            if let message = controller.serverWaitMessage {
                rows.append(
                    .init(
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
            rows.append(
                .init(
                    id: .statusError,
                    content: .error(message),
                    estimatedHeight: 56
                ))
        }
        rows.append(
            .init(
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
            !planDocument.isEmpty
        else {
            rows.append(
                .init(
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
            || !message.turn.workedItemsBeforePlan.isEmpty
        {
            rows.append(
                .init(
                    id: .assistantPlanning(message.id),
                    content: .assistantPlanning(message),
                    estimatedHeight: 44,
                    measurementRevision: revision
                ))
        }
        rows.append(
            .init(
                id: .plan(message.id),
                content: .planDocument(planDocument),
                estimatedHeight: Self.estimatedPlanHeight(planDocument),
                measurementRevision: Self.planMeasurementRevision(planDocument)
            ))
        if !message.turn.workedItemsAfterPlan.isEmpty
            || message.turn.finalText != nil
            || message.turn.stopDetail != nil
            || message.turn.isGenerating
        {
            rows.append(
                .init(
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

            if showsInitialLoadingSpinner, isLoadingTranscriptContent {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.bottom, composerHeight)
                    .allowsHitTesting(false)
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
                        onInitialComposerFocusRequestFulfilled,
                    preservesFocusAfterSend: preservesComposerFocusOnSend,
                    textEditorHandoffRole: composerTextEditorHandoffRole,
                    textEditorHandoffID: composerTextEditorHandoffID,
                    onSendSourceFrameChange: { frame in
                        sendAnimationSourceFrame = frame
                    },
                    onWillSend: { text in
                        onComposerWillSend?(text, sendAnimationSourceFrame ?? .zero)
                    }
                )
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: { height in
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
        return NativeTranscriptView(
            rows: projectedRows,
            initialState: controller.scrollState,
            followsLatest: followsLatest,
            hasOlderHistory: controller.hasOlderHistory,
            showsOlderHistoryLoadingIndicator: presentationRole == .foreground
                && olderHistoryPresentation.isPresented,
            olderHistoryPresentationTarget: olderHistoryPresentation.presentationTarget,
            isLoadingInitialHistory: controller.isLoadingInitialHistory,
            isPreparingInitialProjection: isPreparingTranscript,
            layoutFingerprint: transcriptLayoutFingerprint,
            scrollCommand: scrollCommand,
            sendAnimationRequest: controller.userSendAnimationRequest,
            sendAnimationSourceFrame: sendAnimationSourceFrame,
            presentationRole: presentationRole,
            reduceMotion: reduceMotion,
            scrollIndicatorBottomInset: composerHeight + 6,
            claimSendAnimation: { request in
                controller.claimUserSendAnimation(request)
            },
            onSendAnimationStarted: onSendAnimationStarted,
            onSendAnimationCompleted: { request in
                onSendAnimationCompleted?(request)
            },
            rowContent: { row in
                AnyView(
                    TranscriptVirtualRowContent(row: row, controller: controller)
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
                requestOlderHistoryLoad()
            },
            onOlderHistoryPresented: { token in
                // UIViewRepresentable updates are part of SwiftUI's render
                // transaction. Publish the acknowledgement on the next turn
                // instead of mutating view state from inside that update.
                DispatchQueue.main.async {
                    olderHistoryPresentation.didPresent(token: token)
                }
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

    private var transcriptProjectionRequest: TranscriptProjectionRequest {
        TranscriptProjectionRequest(
            key: controller.transcriptProjectionKey,
            options: .init(
                includesConnectingRow: true,
                bottomSpacerHeight: composerHeight + 24
            )
        )
    }

    private func requestOlderHistoryLoad() {
        guard historyLoadTask == nil, controller.hasOlderHistory,
            !controller.isLoadingOlderHistory
        else { return }
        guard
            let token = olderHistoryPresentation.begin(
                hasOlderHistory: controller.hasOlderHistory
            )
        else { return }
        historyLoadTask = Task { @MainActor in
            defer { historyLoadTask = nil }
            let insertedItemCount = await controller.loadOlderHistory()
            guard !Task.isCancelled else {
                olderHistoryPresentation.cancel(token: token)
                return
            }
            olderHistoryPresentation.requestDidFinish(
                token: token,
                insertedItemCount: insertedItemCount,
                oldestRowKey: insertedItemCount > 0
                    ? projectedRows.first?.layoutKey
                    : nil
            )
        }
    }

    private var transcriptLayoutFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(dynamicTypeSize)
        hasher.combine(displayScale)
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
            hasher.combine(turn.attachments.count)
            for attachment in turn.attachments {
                hasher.combine(attachment.id)
                hasher.combine(attachment.sizeBytes)
            }
        }
        hasher.combine(waitingOnBackgroundTask)
        return hasher.finalize()
    }
}

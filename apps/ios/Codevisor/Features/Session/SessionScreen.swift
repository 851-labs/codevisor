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
    @Environment(AppEnvironment.self) private var environment
    @State private var disclosure = TranscriptDisclosureStore()
    @Namespace private var composerGlassNamespace
    /// Resting measurements stay split so a live resize drag never republishes
    /// transcript geometry. `ComposerBar` owns the card measurement; the
    /// accessory stack changes only when semantic surfaces appear or resize.
    @State private var composerCardHeight: CGFloat = 96
    @State private var composerAccessoryHeight: CGFloat = 0
    /// True while the transcript is parked at the newest content; drives both
    /// auto-scroll and the scroll-to-bottom button, mirroring the macOS
    /// transcript's follow mode.
    @State private var followsLatest = true
    @State private var isAtBottom = true
    /// Height available to the chat area, used to cap composer expansion.
    @State private var availableHeight: CGFloat = 600
    /// True while the composer is dragged to full height; informational
    /// accessories hide until it collapses, while actionable failures remain.
    @State private var composerExpanded = false
    /// Fetches and caches transcript attachment previews via the controller's
    /// authenticated client.
    @State private var attachmentImages: AttachmentImageStore?
    @State private var scrollCommand = TranscriptScrollCommand()
    @State private var historyLoadTask: Task<Void, Never>?
    @State private var olderHistoryPresentation = TranscriptPaginationPresentationGate()
    @State private var showsInitialLoadingSpinner = false
    @State private var projectedRows: [TranscriptVirtualRow] = []
    @State private var projectedRowsVersion: UInt64 = 0
    @State private var projectedSessionID: UUID?
    @State private var isPreparingTranscript = true
    @State private var ownsVisibleTranscriptLifecycle = false
    @State private var textAnimationVisibility = StreamingTextAnimationVisibility(
        initiallyVisible: false
    )
    /// Window-space bounds of the live editor. UIKit uses this as the actual
    /// launch point for the optimistic user row instead of estimating from the
    /// transcript's bottom inset.
    @State private var sendAnimationSourceFrame: CGRect?

    /// The complete resting bottom chrome above the safe-area margin. Every
    /// transcript inset and snapshot crop reads this single value.
    private var composerHeight: CGFloat {
        composerCardHeight + composerAccessoryHeight
    }

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
                publishAttentionFocus(isForeground: false)
                textAnimationVisibility.disappear()
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
                    projectedRowsVersion &+= 1
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
                    projectedRowsVersion &+= 1
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
        publishAttentionFocus(isForeground: shouldOwnLifecycle)
        guard shouldOwnLifecycle != ownsVisibleTranscriptLifecycle else { return }
        ownsVisibleTranscriptLifecycle = shouldOwnLifecycle
        if shouldOwnLifecycle {
            controller.transcriptViewDidAppear()
            textAnimationVisibility.appear()
        } else {
            textAnimationVisibility.disappear()
            controller.transcriptViewDidDisappear()
        }
    }

    /// Read = focus: the foregrounded chat screen is the focused chat. The
    /// coordinator marks it read on open and continuously while open (gated
    /// by scene activity), and never pings for it.
    private func publishAttentionFocus(isForeground: Bool) {
        guard let session = controller.serverSession else { return }
        environment.attentionCoordinator.updateFocus(
            owner: ObjectIdentifier(controller),
            session: isForeground
                ? SessionAttentionFocus(serverId: session.serverId, sessionId: session.id)
                : nil
        )
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

    private var showsScrollToBottom: Bool {
        !composerExpanded && !isAtBottom && hasScrollableContent
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

            GlassEffectContainer(spacing: ComposerGlassStyle.clusterSpacing) {
                composerCluster
                    // The jump control belongs to the same material group but
                    // not its measured vertical stack: showing it must never
                    // change transcript insets or the user's scroll position.
                    .overlay(alignment: .topTrailing) {
                        if showsScrollToBottom {
                            scrollToBottomButton
                                .offset(y: -52)
                                .glassEffectID(
                                    ComposerGlassElement.scrollToBottom.rawValue,
                                    in: composerGlassNamespace
                                )
                                // This control floats well beyond the
                                // container spacing, so Apple recommends
                                // materializing instead of seeking a nearby
                                // shape to morph from.
                                .glassEffectTransition(.materialize)
                                .transition(.opacity)
                        }
                    }
            }
            .animation(Motion.quick(reduceMotion: reduceMotion), value: showsScrollToBottom)
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

    private var composerCluster: some View {
        VStack(spacing: 0) {
            IOSComposerAccessoryStack(
                controller: controller,
                isComposerExpanded: composerExpanded,
                maximumTodoHeight: max(132, min(240, availableHeight * 0.35)),
                glassNamespace: composerGlassNamespace
            )
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: { height in
                if composerAccessoryHeight != height {
                    composerAccessoryHeight = height
                }
            }

            ComposerBar(
                controller: controller,
                // Actionable notices remain visible while fully expanded, so
                // reserve their measured height from the editor's upper bound.
                maxHeight: max(160, availableHeight - composerAccessoryHeight - 12),
                collapsedHeight: $composerCardHeight,
                isExpanded: $composerExpanded,
                showsRunPickers: showsRunPickers,
                initialFocusRequest: initialComposerFocusRequest,
                onInitialFocusRequestFulfilled:
                    onInitialComposerFocusRequestFulfilled,
                preservesFocusAfterSend: preservesComposerFocusOnSend,
                textEditorHandoffRole: composerTextEditorHandoffRole,
                textEditorHandoffID: composerTextEditorHandoffID,
                glassNamespace: composerGlassNamespace,
                onSendSourceFrameChange: { frame in
                    sendAnimationSourceFrame = frame
                },
                onWillSend: { text in
                    onComposerWillSend?(text, sendAnimationSourceFrame ?? .zero)
                }
            )
        }
        .animation(Motion.quick(reduceMotion: reduceMotion), value: composerExpanded)
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

    // MARK: - Native transcript

    private var transcript: some View {
        return ActiveTranscriptProjectionScope(
            controller: controller,
            projectedRows: projectedRows
        ) { activeRows in
            NativeTranscriptView(
                rows: projectedRows,
                activeRows: activeRows,
                rowsVersion: projectedRowsVersion,
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
                                \.streamingTextAnimationVisibility,
                                textAnimationVisibility
                            )
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
        }
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
}

private extension SessionTranscriptView {
    func isUser(_ item: ConversationItem) -> Bool {
        if case .user = item { return true }
        return false
    }

    func isAssistant(_ item: ConversationItem) -> Bool {
        if case .assistant = item { return true }
        return false
    }
}

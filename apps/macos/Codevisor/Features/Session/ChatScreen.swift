//  The chat pane's content: the streaming transcript with the composer
//  floating over the bottom of the history (no divider), and enough bottom
//  inset that the last message can scroll clear of the composer.
//
//  Extracted from SessionScreen so the chat renders through the pane system
//  like any other pane. Everything that must survive unmount/remount —
//  composer text, scroll position, follow mode — lives on SessionController,
//  so tab switches rebuild this view cheaply and correctly.

import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

struct ChatScreen: View {
    @State var authSignInHarnessId: String?
    static let composerBottomMargin: CGFloat = 16

    @Environment(\.theme) var theme
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.openSettings) var openSettings
    @Environment(\.attachmentImages) var attachmentImages
    @Environment(\.quickLook) var quickLook
    @Environment(\.codeHighlightTheme) var codeHighlightTheme
    @Environment(AppEnvironment.self) var environment
    @Bindable var controller: SessionController
    /// The session screen's focus coordinator (shared with the terminals).
    let focus: TerminalFocusController
    /// The pane's retained AppKit presentation. Reattaching this surface keeps
    /// its mounted Markdown rows, TextKit layout, and exact native viewport.
    let presentationSurface: TranscriptPresentationSurface
    @State var isAtBottom: Bool
    @State var autoFollow: Bool
    @State var composerHeight: CGFloat
    @State var isQueueExpanded: Bool
    @State var scrollCommand = TranscriptScrollCommand()
    @State var historyLoadTask: Task<Void, Never>?
    @State var composerMaskSize: CGSize
    @State var isTranscriptMounted: Bool
    @State var isInitialTranscriptReady: Bool
    @State var showsInitialLoadingSpinner = false
    @State var projectedRows: [TranscriptVirtualRow] = []
    @State var projectedRowsVersion: UInt64 = 0
    @State var workedRowsVisibilityCache = TranscriptWorkedRowsVisibilityCache()
    @State var projectedSessionID: UUID?
    /// The native gate may open only for the exact projection request whose
    /// rows have committed. An existing chat first publishes an empty/loading
    /// request, then a history-backed request; a free-running Bool can briefly
    /// describe the old rows as ready during that handoff.
    @State var projectionPublication =
        TranscriptProjectionPublicationState<TranscriptProjectionRequest>()
    @State var presentationVisibilityOwner = UUID()
    @Namespace var composerGlassNamespace

    init(
        controller: SessionController,
        focus: TerminalFocusController,
        presentationSurface: TranscriptPresentationSurface
    ) {
        self.controller = controller
        self.focus = focus
        self.presentationSurface = presentationSurface
        let isWarm = presentationSurface.isWarm
        _isAtBottom = State(initialValue: controller.scrollState?.isAtBottom ?? true)
        _autoFollow = State(
            initialValue: controller.scrollState?.followMode.followsLatest ?? true
        )
        _composerHeight = State(initialValue: presentationSurface.composerHeight)
        _isQueueExpanded = State(initialValue: presentationSurface.isQueueExpanded)
        _composerMaskSize = State(initialValue: presentationSurface.composerMaskSize)
        _isTranscriptMounted = State(initialValue: false)
        _isInitialTranscriptReady = State(initialValue: isWarm)
    }

    var body: some View {
        transcriptSurface
            .onChange(of: controller.userSendSignal) { _, _ in
                autoFollow = true
                scrollCommand.token &+= 1
            }
            .onChange(of: isQueueExpanded) { _, isExpanded in
                presentationSurface.isQueueExpanded = isExpanded
            }
            .overlay { initialLoadingOverlay }
            .harnessSignInSheet(
                harnessId: $authSignInHarnessId,
                serverId: controller.project.serverId
            )
            .overlay(alignment: .bottom) { bottomChromeOverlay }
            .animation(Motion.quick(reduceMotion: reduceMotion), value: isAtBottom)
            .onAppear {
                autoFollow = controller.scrollState?.followMode.followsLatest ?? true
                isAtBottom = controller.scrollState?.isAtBottom ?? true
                controller.transcriptViewDidAppear()
                presentationSurface.appear(owner: presentationVisibilityOwner)
            }
            .onDisappear {
                presentationSurface.disappear(owner: presentationVisibilityOwner)
                historyLoadTask?.cancel()
                historyLoadTask = nil
                controller.transcriptViewDidDisappear()
            }
            // Give the new pane shell, split chrome, and composer one committed
            // frame before constructing the AppKit virtualizer. Until then the
            // transcript region is an opaque, correctly-sized blank surface.
            .task(id: ObjectIdentifier(controller)) {
                let hasWarmPresentation = presentationSurface.isWarm
                isTranscriptMounted = false
                isInitialTranscriptReady = hasWarmPresentation
                showsInitialLoadingSpinner = false
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                isTranscriptMounted = true
            }
            // Every chat pane loads its own history: only the ROUTED session's
            // controller is prepared by the container, but a workspace can show
            // several chats at once (splits, tabs) — without this, the others
            // render empty transcripts.
            .task(id: ObjectIdentifier(controller)) {
                if controller.resumeAgentSessionId?.isEmpty == false {
                    // Existing chats know their harness. Refresh only that one in
                    // parallel; neither config inspection nor runtime startup may
                    // hold the first transcript page behind them.
                    async let capabilities: Void = controller.prepareExistingSessionCapabilities()
                    if !AppPreview.isRunning {
                        await controller.connectIfNeeded()
                    }
                    await capabilities
                } else {
                    if !controller.isPrepared && !controller.isConnected {
                        await controller.prepare()
                    }
                    if !AppPreview.isRunning {
                        await controller.connectIfNeeded()
                    }
                }
            }
            .task(id: transcriptProjectionRequest) {
                let request = transcriptProjectionRequest
                let key = request.key
                let input = controller.transcriptProjectionInput
                if projectedSessionID != key.sessionID {
                    projectedRows = []
                    projectedRowsVersion &+= 1
                    projectedSessionID = key.sessionID
                    projectionPublication.reset()
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
                    projectionPublication.publish(request)
                } catch is CancellationError {
                    return
                } catch {
                    // Projection is pure and currently only throws for
                    // cancellation. Do not authorize a stale projection if
                    // that contract changes.
                }
            }
            .task(id: isInitialTranscriptReady) {
                showsInitialLoadingSpinner = false
                guard !isInitialTranscriptReady else { return }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, !isInitialTranscriptReady else { return }
                showsInitialLoadingSpinner = true
            }
    }

}

import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

struct ChatScreen: View {
  static let composerBottomMargin: CGFloat = 16
  static let composerTopPadding: CGFloat = 24
  static let composerHorizontalPadding: CGFloat = 24
  static let composerMaxWidth: CGFloat = 880

  @Environment(\.dynamicTypeSize) var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.openSettings) var openSettings
  @Environment(\.quickLook) var quickLook
  @Environment(\.openFileDocument) var openFileDocument
  @Environment(\.openSubagent) var openSubagent
  @Environment(\.pluginAppPresenter) var pluginAppPresenter
  @Environment(\.transcriptWebLinkActions) var transcriptWebLinkActions
  @Environment(\.codeHighlightTheme) var codeHighlightTheme
  @Environment(\.usesSlimComposer) var usesSlimComposer
  @Environment(\.transcriptTopChromeHeight) var transcriptTopChromeHeight
  @Environment(AppEnvironment.self) var environment
  @Environment(\.allowsRemoteComputerUsePreview) var allowsRemoteComputerUsePreview
  @Environment(\.workspaceChildAgents) var workspaceChildAgents
  @Environment(\.reusesChatPage) var reusesChatPage
  @Bindable var controller: SessionController
  let focus: TerminalFocusController
  let presentationSurface: TranscriptPresentationSurface
  let isReadOnly: Bool
  let presentsBotConversation: Bool
  @State var historyLoadTask: Task<Void, Never>?
  @State var reportsScrollState = true
  @State var transcriptMount = TranscriptMountLatch()
  @State var showsInitialLoadingSpinner = false
  @State var presentationVisibilityOwner = UUID()
  @State var showsPromptQueue = false
  @State var queueSends = QueueSendObserver()
  @State var isSlashPalettePresented = false
  @Namespace var composerGlassNamespace
  var composerCardStyle = ComposerCardStyle()

  private struct ContentLoadingIdentity: Equatable {
    let controller: ObjectIdentifier
    let isMounted: Bool
  }

  private var contentLoadingIdentity: ContentLoadingIdentity {
    .init(controller: ObjectIdentifier(controller), isMounted: isTranscriptMounted)
  }

  var mountedProjectionRequest: TranscriptProjectionRequest? {
    isTranscriptMounted ? transcriptProjectionRequest : nil
  }

  init(
    controller: SessionController,
    focus: TerminalFocusController,
    presentationSurface: TranscriptPresentationSurface,
    isReadOnly: Bool = false,
    presentsBotConversation: Bool = false
  ) {
    self.controller = controller
    self.focus = focus
    self.presentationSurface = presentationSurface
    self.isReadOnly = isReadOnly
    self.presentsBotConversation = presentsBotConversation
  }

  var attachmentImages: AttachmentImageStore { SessionAttachmentImages.store(for: controller) }

  var projection: TranscriptSettledProjection { presentationSurface.projection }

  var composerHeight: CGFloat { isReadOnly ? 0 : presentationSurface.composer.height }

  var body: some View {
    transcriptSurface
      .onChange(of: controller.userSendSignal) { _, _ in
        autoFollow = true
        scrollCommand.token &+= 1
      }
      .onChange(of: controller.transcriptRevealRequest, initial: true) { _, _ in
        revealRequestedToolCall()
      }
      .onChange(of: controller.quoteRevealRequest, initial: true) { _, _ in
        revealRequestedQuote()
      }
      .onChange(of: controller.transcriptPickSignal) { _, _ in
        presentationSurface.ensureScrollView().holdViewportForComposerChange()
      }
      .overlay { initialLoadingOverlay }
      .overlay(alignment: .bottom) { bottomChromeOverlay }
      .overlay(alignment: .topTrailing) { findBarOverlay }
      .focusedValue(\.transcriptFind, presentationSurface.findModel)
      .overlay { livePreviewPiPOverlay }
      .modifier(ChatSetupSheets(controller: controller))
      .environment(\.attachmentImages, attachmentImages)
      .pointerStyle(.default)
      .transaction(value: ObjectIdentifier(controller)) { $0.animation = nil }
      .animation(Motion.quick(reduceMotion: reduceMotion), value: isAtBottom)
      .animation(Motion.quick(reduceMotion: reduceMotion), value: earlierHistoryCollapse)
      .animation(Motion.quick(reduceMotion: reduceMotion), value: presentationSurface.findModel.isPresented)
      .onAppear {
        reportsScrollState = true
        autoFollow = controller.scrollState?.followMode.followsLatest ?? true
        isAtBottom = controller.scrollState?.isAtBottom ?? true
      }
      .onWorkspaceVisibilityChange(show: showPresentation, hide: hidePresentation)
      .onDisappear {
        reportsScrollState = false
        historyLoadTask?.cancel()
        historyLoadTask = nil
      }
      .task(id: ObjectIdentifier(controller)) {
        let hasWarmPresentation = presentationSurface.isWarm
        isInitialTranscriptReady = hasWarmPresentation
        showsInitialLoadingSpinner = false
        if hasWarmPresentation {
          isTranscriptMounted = true
          return
        }
        guard !isTranscriptMounted else { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled else { return }
        isTranscriptMounted = true
      }
      .onChange(of: presentsBotConversation, initial: true) {
        controller.presentBotConversation(presentsBotConversation)
      }
      .onChange(of: ObjectIdentifier(controller), initial: true) { QueuedPromptFlight.install(on: controller) }
      .onChange(of: ChatPresentationTarget(controller: controller, surface: presentationSurface)) { old, _ in
        present(replacing: old)
      }
      .onChange(of: isTranscriptMounted, initial: true) { _, isMounted in
        if isMounted { transcriptMount.hasMounted = true }
      }
      .onChange(of: hasPromptQueue, initial: true) { _, hasQueue in
        updatePromptQueueVisibility(hasQueue)
      }
      .task(id: contentLoadingIdentity) {
        guard isTranscriptMounted else { return }
        guard !isReadOnly else {
          await connectForReading()
          return
        }
        if controller.resumeAgentSessionId?.isEmpty == false {
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
      .task(id: mountedProjectionRequest) {
        submitProjection()
      }
      .task(id: isInitialTranscriptReady) {
        showsInitialLoadingSpinner = false
        guard !isInitialTranscriptReady else { return }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, !isInitialTranscriptReady else { return }
        showsInitialLoadingSpinner = true
      }
  }

  private func showPresentation() {
    controller.presentationClock.viewDidAppear()
    presentationSurface.appear(owner: presentationVisibilityOwner)
  }

  private func hidePresentation() {
    presentationSurface.disappear(owner: presentationVisibilityOwner)
    controller.presentationClock.viewDidDisappear()
  }

  private func present(replacing old: ChatPresentationTarget) {
    historyLoadTask?.cancel()
    historyLoadTask = nil
    _ = queueSends.sentSinceLastCheck(in: controller)
    withTransaction(\.disablesAnimations, true) { showsPromptQueue = hasPromptQueue }
    if let textView = focus.composerTextView, let chatId = controller.serverSession?.id {
      focus.registerComposer(textView, forChat: chatId)
    }
    guard old.surface.isPresented(by: presentationVisibilityOwner) else { return }

    old.surface.disappear(owner: presentationVisibilityOwner)
    old.controller.presentationClock.viewDidDisappear()
    showPresentation()
  }
}

private struct ChatPresentationTarget: Equatable {
  let controller: SessionController
  let surface: TranscriptPresentationSurface

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.controller === rhs.controller && lhs.surface === rhs.surface
  }
}

final class TranscriptMountLatch {
  var hasMounted = false
}

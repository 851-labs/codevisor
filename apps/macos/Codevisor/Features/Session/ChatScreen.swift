import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

struct ChatScreen: View {
  static let composerBottomMargin: CGFloat = 16
  static let composerHorizontalPadding: CGFloat = 24
  static let composerMaxWidth: CGFloat = 880

  @Environment(\.dynamicTypeSize) var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.openSettings) var openSettings
  @Environment(\.attachmentImages) var attachmentImages
  @Environment(\.quickLook) var quickLook
  @Environment(\.openFileDocument) var openFileDocument
  @Environment(\.openSubagent) var openSubagent
  @Environment(\.pluginAppPresenter) var pluginAppPresenter
  @Environment(\.transcriptWebLinkActions) var transcriptWebLinkActions
  @Environment(\.codeHighlightTheme) var codeHighlightTheme
  @Environment(\.usesSlimComposer) var usesSlimComposer
  @Environment(\.transcriptTopChromeHeight) var transcriptTopChromeHeight
  @Environment(AppEnvironment.self) var environment
  @Environment(\.computerUsePiPPane) var computerUsePiPPane
  @Bindable var controller: SessionController
  let focus: TerminalFocusController
  let presentationSurface: TranscriptPresentationSurface
  let isReadOnly: Bool
  let presentsBotConversation: Bool
  @State var isAtBottom: Bool
  @State var earlierHistoryCollapse: TranscriptEarlierHistoryCollapse?
  @State var autoFollow: Bool
  @State var composerHeight: CGFloat
  @State var composerCardHeight: CGFloat = 0
  @State var scrollCommand = TranscriptScrollCommand()
  @State var historyLoadTask: Task<Void, Never>?
  @State var isTranscriptMounted: Bool
  @State var isInitialTranscriptReady: Bool
  @State var showsInitialLoadingSpinner = false
  @State var projectedRows: [TranscriptVirtualRow] = []
  @State var projectedRowsVersion: UInt64 = 0
  @State var workedRowsVisibilityCache = TranscriptWorkedRowsVisibilityCache()
  @State var projectedSessionID: UUID?
  @State var projectionPublication =
    TranscriptProjectionPublicationState<TranscriptProjectionRequest>()
  @State var presentationVisibilityOwner = UUID()
  @Namespace var composerGlassNamespace
  var composerCardStyle = ComposerCardStyle()

  private struct ContentLoadingIdentity: Equatable {
    let controller: ObjectIdentifier
    let isMounted: Bool
  }

  private var contentLoadingIdentity: ContentLoadingIdentity {
    .init(controller: ObjectIdentifier(controller), isMounted: isTranscriptMounted)
  }

  private var mountedProjectionRequest: TranscriptProjectionRequest? {
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
    let isWarm = presentationSurface.isWarm
    _isAtBottom = State(initialValue: controller.scrollState?.isAtBottom ?? true)
    _autoFollow = State(
      initialValue: controller.scrollState?.followMode.followsLatest ?? true
    )
    _composerHeight = State(initialValue: isReadOnly ? 0 : presentationSurface.composerHeight)
    _isTranscriptMounted = State(initialValue: isWarm)
    _isInitialTranscriptReady = State(initialValue: isWarm)
  }

  var body: some View {
    transcriptSurface
      .onChange(of: controller.userSendSignal) { _, _ in
        autoFollow = true
        scrollCommand.token &+= 1
      }
      .overlay { initialLoadingOverlay }
      .overlay(alignment: .bottom) { bottomChromeOverlay }
      .overlay(alignment: .topTrailing) { findBarOverlay }
      .focusedValue(\.transcriptFind, presentationSurface.findModel)
      .overlay { livePreviewPiPOverlay }
      .overlay { PluginAppPipOverlay(chatSessionId: controller.serverSession?.id) }
      .sheet(item: $controller.presentedSetupRequest) { request in
        SetupRequestSheet(request: request, controller: controller)
      }
      .pointerStyle(.default)
      .animation(Motion.quick(reduceMotion: reduceMotion), value: isAtBottom)
      .animation(Motion.quick(reduceMotion: reduceMotion), value: earlierHistoryCollapse)
      .animation(Motion.quick(reduceMotion: reduceMotion), value: presentationSurface.findModel.isPresented)
      .onAppear {
        autoFollow = controller.scrollState?.followMode.followsLatest ?? true
        isAtBottom = controller.scrollState?.isAtBottom ?? true
        controller.presentationClock.viewDidAppear()
        presentationSurface.appear(owner: presentationVisibilityOwner)
      }
      .onDisappear {
        presentationSurface.disappear(owner: presentationVisibilityOwner)
        historyLoadTask?.cancel()
        historyLoadTask = nil
        controller.presentationClock.viewDidDisappear()
      }
      .task(id: ObjectIdentifier(controller)) {
        let hasWarmPresentation = presentationSurface.isWarm
        isInitialTranscriptReady = hasWarmPresentation
        showsInitialLoadingSpinner = false
        if hasWarmPresentation {
          isTranscriptMounted = true
          return
        }
        isTranscriptMounted = false
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled else { return }
        isTranscriptMounted = true
      }
      .task(id: contentLoadingIdentity) {
        if presentsBotConversation { controller.presentBotConversation() }
        guard isTranscriptMounted, !isReadOnly else { return }
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
        guard let request = mountedProjectionRequest else { return }
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

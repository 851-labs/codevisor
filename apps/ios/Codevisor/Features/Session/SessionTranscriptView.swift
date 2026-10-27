import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import UIKit

extension Notification.Name {
  static let codevisorOpenSettings = Notification.Name("codevisor.open-settings")
}

struct SessionTranscriptView: View {
  @Environment(\.openFileDocument) var openFileDocument
  @Environment(\.openSubagent) var openSubagent
  static let transcriptMeasurementSchemaVersion = 3
  static let transcriptBottomBreathingRoom: CGFloat = 8
  static let composerBottomMargin: CGFloat = 6

  @Bindable var controller: SessionController
  let presentationSurface: TranscriptPresentationSurface
  var showsRunPickers: Bool = false
  var isReadOnly: Bool = false
  var initialComposerFocusRequest: UUID? = nil
  var onInitialComposerFocusRequestFulfilled: ((UUID) -> Void)? = nil
  var presentationRole: TranscriptPresentationRole = .foreground
  var onSendAnimationCompleted: ((UserSendAnimationRequest) -> Void)? = nil
  var onSendAnimationStarted: ((UserSendAnimationRequest) -> Void)? = nil
  var onComposerWillSend: ((String, CGRect) -> Void)? = nil
  var preservesComposerFocusOnSend = false
  var tracksKeyboardInset = true
  var topChromeWindowBottom: CGFloat = 0
  var layoutNamespaceToken: UUID? = nil
  var composerTextEditorHandoffRole: ComposerTextEditorHandoffRole = .none
  var composerTextEditorHandoffID: UUID? = nil
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.displayScale) var displayScale
  @Environment(\.dynamicTypeSize) var dynamicTypeSize
  @Environment(\.scenePhase) var scenePhase
  @Environment(\.markdownTheme) var markdownTheme
  @Environment(AppEnvironment.self) var environment
  @State private var presentationOwner = UUID()
  var disclosure: TranscriptDisclosureStore { presentationSurface.disclosure }
  @Namespace var composerGlassNamespace
  @State var composerCardHeight: CGFloat = 96
  @State var sendAnimationsStarted = 0
  @State var composerAccessoryHeight: CGFloat = 0
  @State var followsLatest = true
  @State var isAtBottom = true
  @State var earlierHistoryCollapse: TranscriptEarlierHistoryCollapse?
  @State var availableHeight: CGFloat = 600
  @State var transcriptWindowBottom: CGFloat = 0
  @State var chatAreaWindowBottom: CGFloat = 0
  @State var offeredChatWindowFrame: CGRect = .zero
  @State var keyboardOverlap: CGFloat = 0
  @State var keyboardFreeChatHeight: CGFloat = 0
  @State var keyboardAvoidingChatHeight: CGFloat = 0
  @State var keyboardInset = ChatKeyboardInset()
  @State var composerExpanded = false
  @State var attachmentImages: AttachmentImageStore?
  @State var quickLook = QuickLookController()
  @State var scrollCommand = TranscriptScrollCommand()
  @State var historyLoadTask: Task<Void, Never>?
  @State var olderHistoryPresentation = TranscriptPaginationPresentationGate()
  @State var showsInitialLoadingSpinner = false
  @State var projectedRows: [TranscriptVirtualRow] = []
  @State var projectedRowsVersion: UInt64 = 0
  @State var workedRowsVisibilityCache = TranscriptWorkedRowsVisibilityCache()
  @State var projectedSessionID: UUID?
  @State var projectionPublication =
    TranscriptProjectionPublicationState<TranscriptProjectionRequest>()
  @State var ownsVisibleTranscriptLifecycle = false
  var textAnimationVisibility: StreamingTextAnimationVisibility {
    presentationSurface.textAnimationVisibility
  }
  var textAnimationRegistry: StreamingTextAnimationRegistry {
    presentationSurface.textAnimationRegistry
  }
  @State var sendAnimationSourceFrame: CGRect?
  @State var queueSendAnimation = IOSQueueSendAnimation()

  var userBubbleStyle: UserBubbleStyle {
    controller.presentsBotConversation ? .accent : .standard
  }

  var composerHeight: CGFloat {
    isReadOnly || controller.hidesComposerForAnswer ? 0 : composerCardHeight + composerAccessoryHeight
  }

  var body: some View {
    chat
      .attachmentQuickLookPreview(
        Binding(get: { quickLook.previewURL }, set: { quickLook.updatePreviewURL($0) })
      )
      .acknowledgesPresentedTurnAttention(
        controller: controller,
        presentationRole: presentationRole
      )
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
        IOSNavigationDiagnostics.record(
          "transcript.roleChanged", "role=\(role) session=\(diagnosticSessionID)")
        updateVisibleTranscriptLifecycle(for: role)
      }
      .onAppear {
        IOSNavigationDiagnostics.record(
          "transcript.appear", "session=\(diagnosticSessionID) role=\(presentationRole)")
      }
      .onDisappear {
        IOSNavigationDiagnostics.record(
          "transcript.disappear", "session=\(diagnosticSessionID) role=\(presentationRole)")
      }
      .onChange(of: ObjectIdentifier(controller)) { _, _ in
        IOSNavigationDiagnostics.record(
          "transcript.controllerChanged", "session=\(diagnosticSessionID)")
      }
      .onChange(of: projectedRows.isEmpty) { _, isEmpty in
        IOSNavigationDiagnostics.record(
          "transcript.rowsEmptyChanged", "empty=\(isEmpty) session=\(diagnosticSessionID)")
      }
      .onChange(of: controller.isLoadingInitialHistory) { _, loading in
        IOSNavigationDiagnostics.record(
          "transcript.isLoadingInitialHistory", "value=\(loading) session=\(diagnosticSessionID)")
      }
      .onChange(of: showsWatermark) { _, shows in
        IOSNavigationDiagnostics.record(
          "transcript.watermark", "shows=\(shows) session=\(diagnosticSessionID)")
      }
      .onChange(of: controller.settledConversation.count) { old, new in
        IOSNavigationDiagnostics.record(
          "transcript.settledCount", "\(old)->\(new) session=\(diagnosticSessionID)")
      }
      .onChange(of: scenePhase, initial: true) { _, phase in
        if phase == .active {
          textAnimationRegistry.resumePlayback()
        } else {
          textAnimationRegistry.suspendPlayback()
        }
      }
      .onDisappear { [controller] in
        historyLoadTask?.cancel()
        historyLoadTask = nil
        olderHistoryPresentation.cancel()
        publishAttentionFocus(isForeground: false)
        presentationSurface.disappear(owner: presentationOwner)
        TranscriptPresentationSurfaceCache.shared.scheduleTrim()
        if ownsVisibleTranscriptLifecycle {
          ownsVisibleTranscriptLifecycle = false
          controller.presentationClock.viewDidDisappear()
        }
      }
      .environment(\.attachmentImages, attachmentImages)
      .environment(\.quickLook, quickLook)
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
          olderHistoryPresentation.projectionDidPublish(
            key: request.key,
            revision: projectedRowsVersion
          )
        } catch is CancellationError {
          return
        } catch {
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

  private var diagnosticSessionID: String {
    controller.serverSession.map { String($0.id.uuidString.prefix(8)) } ?? "draft"
  }

  var isLoadingTranscriptContent: Bool {
    (isPreparingTranscript && projectedRows.isEmpty)
      || (!showsWatermark && !presentationSurface.hasPresentedContent)
      || (controller.isLoadingInitialHistory
        && controller.settledConversation.isEmpty
        && !controller.hasActiveItem)
  }

  func installAttachmentImageStoreIfNeeded() {
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
      fetchPreview: { [weak controller] source in
        guard let controller else { throw SessionControllerError.serverUnavailable }
        return try await controller.filePreview(for: source)
      },
      fetchPrefix: { [weak controller] source, length in
        guard let controller else { throw SessionControllerError.serverUnavailable }
        return try await controller.filePrefix(for: source, length: length)
      },
      version: { [weak controller] source in
        guard let controller else {
          throw SessionControllerError.serverUnavailable
        }
        return try await controller.fileVersion(for: source)
      }
    )
  }

  func updateVisibleTranscriptLifecycle(for role: TranscriptPresentationRole) {
    let shouldOwnLifecycle = role == .foreground
    publishAttentionFocus(isForeground: shouldOwnLifecycle)
    guard shouldOwnLifecycle != ownsVisibleTranscriptLifecycle else { return }
    ownsVisibleTranscriptLifecycle = shouldOwnLifecycle
    if shouldOwnLifecycle {
      presentationSurface.appear(owner: presentationOwner)
      controller.presentationClock.viewDidAppear()
    } else {
      presentationSurface.disappear(owner: presentationOwner)
      controller.presentationClock.viewDidDisappear()
    }
  }

  func publishAttentionFocus(isForeground: Bool) {
    guard let session = controller.serverSession else { return }
    environment.attentionCoordinator.updateFocus(
      owner: ObjectIdentifier(controller),
      session: isForeground
        ? SessionAttentionFocus(serverId: session.serverId, sessionId: session.id)
        : nil
    )
  }

  var showsWatermark: Bool {
    guard !controller.presentsBotConversation else { return false }
    guard controller.pendingUserMessage == nil, controller.setupPhases.isEmpty else { return false }
    guard controller.sessionErrorMessage == nil else { return false }
    guard !controller.isLoadingInitialHistory, controller.serverWaitMessage == nil else { return false }
    switch controller.status {
    case .connecting, .failed: return false
    case .idle: break
    }
    return controller.settledConversation.isEmpty && !controller.hasActiveItem
  }

  var hasScrollableContent: Bool {
    !controller.settledConversation.isEmpty || controller.hasActiveItem
  }

  var showsScrollToBottom: Bool {
    !composerExpanded && !isAtBottom && hasScrollableContent
  }

  var chatLayers: some View {
    ZStack(alignment: .bottom) {
      Color.clear
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: { height in
          availableHeight = height
        }
        .background {
          WindowFrameProbe { offeredChatWindowFrame = $0 }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      transcriptExtentProbe
      CodevisorSymbol.codevisorMark.image
        .font(.system(size: 90))
        .foregroundStyle(Color.primary.opacity(0.08))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.bottom, composerHeight + 20)
        .allowsHitTesting(false)
        .opacity(showsWatermark ? 1 : 0)
        .animation(Motion.quick(reduceMotion: reduceMotion), value: showsWatermark)
      transcript

      if showsInitialLoadingSpinner, isLoadingTranscriptContent {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
          .padding(.bottom, composerHeight)
          .allowsHitTesting(false)
      }

      if isReadOnly {
        readOnlyScrollControl
      } else {
        composerChrome
          .opacity(controller.hidesComposerForAnswer ? 0 : 1)
          .allowsHitTesting(!controller.hidesComposerForAnswer)
          .accessibilityHidden(controller.hidesComposerForAnswer)
          .animation(Motion.quick(reduceMotion: reduceMotion), value: controller.hidesComposerForAnswer)
      }
    }
  }

  var composerCluster: some View {
    VStack(spacing: 0) {
      IOSComposerAccessoryStack(
        controller: controller,
        isComposerExpanded: composerExpanded,
        maximumTodoHeight: max(132, min(240, availableHeight * 0.35)),
        glassNamespace: composerGlassNamespace,
        queueSendAnimation: queueSendAnimation
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
        maxHeight: composerMaxHeight,
        collapsedHeight: $composerCardHeight,
        isExpanded: $composerExpanded,
        showsRunPickers: showsRunPickers,
        initialFocusRequest: initialComposerFocusRequest,
        onInitialFocusRequestFulfilled:
          onInitialComposerFocusRequestFulfilled,
        preservesFocusAfterSend: preservesComposerFocusOnSend,
        textEditorHandoffRole: composerTextEditorHandoffRole,
        textEditorHandoffID: composerTextEditorHandoffID,
        sendAnimationsStarted: sendAnimationsStarted,
        glassNamespace: composerGlassNamespace,
        onSendSourceFrameChange: { frame in
          sendAnimationSourceFrame = frame
        },
        onWillSend: { text, delivery in
          if controller.sendLandsInQueue(delivery) {
            TranscriptSendStaging.shared.cancel(session: ObjectIdentifier(controller))
            if !reduceMotion {
              queueSendAnimation.stage(
                text: text,
                queue: controller.queuedPrompts,
                sourceFrame: sendAnimationSourceFrame ?? .zero,
                in: UIWindow.codevisorKeyWindow
              )
            }
            return
          }
          queueSendAnimation.cancel()
          if !reduceMotion {
            SentAttachmentThumbnails.prepare(controller.composerAttachments)
            ComposerSendStaging.stage(
              session: ObjectIdentifier(controller),
              sourceFrame: sendAnimationSourceFrame ?? .zero,
              style: userBubbleStyle,
              followsComposer: !preservesComposerFocusOnSend,
              attachmentIDs: controller.composerAttachments.compactMap(\.uploadedFileID)
            )
          }
          onComposerWillSend?(text, sendAnimationSourceFrame ?? .zero)
        }
      )
    }
    .animation(Motion.quick(reduceMotion: reduceMotion), value: composerExpanded)
    .onChange(of: controller.queuedPrompts) { _, queue in
      queueSendAnimation.queueDidChange(queue)
    }
    .onChange(of: controller.errorMessage) { _, error in
      if error != nil { queueSendAnimation.cancel() }
    }
    .onChange(of: ObjectIdentifier(controller)) { _, _ in
      queueSendAnimation.cancel()
    }
    .onChange(of: controller.userSendAnimationRequest) { _, _ in
      queueSendAnimation.cancel()
    }
    .onChange(of: reduceMotion) { _, reduced in
      if reduced { queueSendAnimation.cancel() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { queueSendAnimation.cancel() }
    }
    .onDisappear { queueSendAnimation.cancel() }
  }
}

extension SessionTranscriptView {
  var composerMaxHeight: CGFloat {
    max(
      160,
      visibleChatHeight - topContentClearance - Self.composerBottomMargin - 6 - composerAccessoryHeight
    )
  }

  var topContentClearance: CGFloat {
    guard offeredChatWindowFrame.height > 0, topChromeWindowBottom > 0 else { return 0 }
    return max(0, topChromeWindowBottom - offeredChatWindowFrame.minY)
  }

  @ViewBuilder
  var chat: some View {
    if tracksKeyboardInset {
      keyboardInsetChat
    } else {
      chatLayers
        .background {
          ChatSurfaceBackground()
            .ignoresSafeArea()
        }
        .background { chatAreaExtentProbe }
    }
  }

  var visibleChatHeight: CGFloat {
    let offered = offeredChatWindowFrame
    guard offered.height > 0, let window = UIWindow.codevisorKeyWindow else { return availableHeight }
    let safeBottom = window.bounds.maxY - window.safeAreaInsets.bottom
    let visibleBottom = min(offered.maxY, safeBottom)
    return min(availableHeight, max(0, visibleBottom - offered.minY))
  }

  var transcriptExtentProbe: some View {
    WindowFrameProbe { frame in
      transcriptWindowBottom = frame.maxY
    }
    .ignoresSafeArea(.container, edges: [.top, .bottom])
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  var chatAreaExtentProbe: some View {
    WindowFrameProbe { frame in
      chatAreaWindowBottom = frame.maxY
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  var transcriptBottomObstruction: CGFloat {
    let belowComposer = max(0, transcriptWindowBottom - chatAreaWindowBottom)
    return composerHeight + Self.composerBottomMargin + belowComposer
  }
}

extension SessionTranscriptView {
  var composerChrome: some View {
    GlassEffectContainer(spacing: ComposerGlassStyle.clusterSpacing) {
      composerCluster
        .frame(maxWidth: VirtualizedTranscriptScrollView.maxRowWidth)
        .overlay(alignment: .topTrailing) {
          GlassEffectContainer(spacing: ComposerGlassStyle.clusterSpacing) {
            transcriptScrollControls
          }
          .offset(y: -52)
        }
    }
    .animation(Motion.quick(reduceMotion: reduceMotion), value: showsScrollToBottom)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: visibleEarlierHistoryCollapse)
    .padding(.horizontal, 10)
    .padding(.bottom, Self.composerBottomMargin)
  }

  var readOnlyScrollControl: some View {
    GlassEffectContainer(spacing: ComposerGlassStyle.clusterSpacing) {
      transcriptScrollControls
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: showsScrollToBottom)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: visibleEarlierHistoryCollapse)
    .padding(.horizontal, 16)
    .padding(.bottom, Self.composerBottomMargin + 10)
  }
}

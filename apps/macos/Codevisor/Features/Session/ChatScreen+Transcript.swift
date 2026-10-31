import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

extension ChatScreen {
  func revealRequestedToolCall() {
    guard let request = controller.transcriptRevealRequest else { return }

    controller.transcriptRevealRequest = nil
    Task { await revealToolCall(request.toolCallId) }
  }

  private func revealToolCall(_ toolCallId: String) async {
    guard let location = await controller.workedItemLocation(ofToolCall: toolCallId) else { return }

    TranscriptWorkedItemReveal.expand(location, in: controller.disclosure)
    presentationSurface.ensureScrollView().reveal(location)
  }

  var transcriptImageActions: MarkdownImageActions {
    TranscriptMarkdownImageOpener.actions(
      quickLook: quickLook, attachmentImages: attachmentImages, openDocument: openFileDocument)
  }

  var transcriptSurface: some View {
    ZStack {
      Color.clear
      if isTranscriptMounted {
        ActiveTranscriptProjectionScope(
          controller: controller,
          projectedRows: projectedRows
        ) {
          activeRows, activeRowsVersion, isActiveProjectionPending, isAwaitingFirstActiveProjection,
          activeTextRestorationID in
          let visibleRows = workedRowsVisibilityCache.presentSettled(
            projectedRows,
            sourceVersion: projectedRowsVersion,
            disclosure: controller.disclosure
          )
          let visibleActiveRows = TranscriptWorkedRowsVisibility.presentActive(
            activeRows,
            disclosure: controller.disclosure,
            controller: controller
          )
          NativeTranscriptView(
            presentationSurface: presentationSurface,
            input: TranscriptSurfaceInput(
              sessionController: controller,
              rows: visibleRows.rows,
              activeRows: visibleActiveRows.rows,
              hiddenActiveStreamIDs: visibleActiveRows.hiddenStreamIDs,
              activeRowsVersion: TranscriptRowSetRevision(
                sourceRevision: activeRowsVersion,
                visibilityRevision: visibleActiveRows.visibilityRevision
              ),
              rowsVersion: TranscriptRowSetRevision(
                sourceRevision: projectedRowsVersion,
                visibilityRevision: visibleRows.visibilityRevision
              ),
              projectionRevision: projectedRowsVersion,
              initialState: controller.scrollState,
              followsLatest: autoFollow,
              hasOlderHistory: hasOlderHistory,
              showsOlderHistoryLoadingIndicator: isLoadingOlderHistory,
              isLoadingInitialHistory: controller.isAwaitingInitialHistory,
              isPreparingInitialProjection: isPreparingTranscript,
              isActiveProjectionPending: isActiveProjectionPending,
              isAwaitingFirstActiveProjection: isAwaitingFirstActiveProjection,
              activeTextRestorationID: activeTextRestorationID,
              layoutFingerprint: transcriptLayoutFingerprint,
              scrollCommand: scrollCommand,
              sendAnimationRequest: controller.userSendAnimationRequest,
              textAnimationRegistry: presentationSurface.textAnimationRegistry,
              allowsLiveTextAnimation: presentationSurface.textAnimationVisibility.isVisible,
              reduceMotion: reduceMotion,
              bottomFade: transcriptBottomFade
            ),
            callbacks: TranscriptSurfaceCallbacks(
              claimSendAnimation: { request in
                controller.claimUserSendAnimation(request)
              },
              rowContent: { row in
                AnyView(
                  TranscriptRowContentView(row: row, controller: controller, leaves: rowLeaves)
                    .reportsStreamingTextAnimationActivity()
                    .markdownLinkHandler { url in
                      TranscriptMarkdownLinkOpener.open(
                        url, quickLook: quickLook, attachmentImages: attachmentImages,
                        openDocument: openFileDocument)
                    }
                    .markdownImageActions(transcriptImageActions)
                    .markdownWebLinkActions(transcriptWebLinkActions)
                    .environment(\.attachmentImages, attachmentImages)
                    .environment(\.openFileDocument, openFileDocument)
                    .environment(\.openSubagent, openSubagent)
                    .environment(\.hoverTrackingSuspended, controller.isSending)
                    .environment(\.userBubbleStyle, presentsBotConversation ? .accent : .standard)
                    .environment(\.transcriptDisclosure, controller.disclosure)
                    .environment(\.transcriptController, controller)
                    .environment(
                      \.pluginAppHost,
                      PluginAppHost(environment: environment, session: controller, presenter: pluginAppPresenter)
                    )
                    .environment(
                      \.streamingTextAnimationVisibility,
                      presentationSurface.textAnimationVisibility
                    )
                    .environment(
                      \.streamingTextAnimationRegistry,
                      presentationSurface.textAnimationRegistry
                    )
                    .environment(
                      \.runningSubagentToolCallIds,
                      controller.runningSubagentToolCallIds
                    )
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
                  if autoFollow != follows { autoFollow = follows }
                }
              },
              onNearTop: {
                requestOlderHistoryLoad()
              },
              markdownImageLoader: attachmentImages.markdownImageLoader,
              openMarkdownLink: { url in
                TranscriptMarkdownLinkOpener.open(
                  url, quickLook: quickLook, attachmentImages: attachmentImages,
                  openDocument: openFileDocument)
              },
              markdownImageActions: transcriptImageActions,
              markdownWebLinkActions: transcriptWebLinkActions,
              onEarlierHistoryCollapseChange: { collapse in
                DispatchQueue.main.async {
                  if earlierHistoryCollapse != collapse { earlierHistoryCollapse = collapse }
                }
              }
            ),
            markdownRowStyle: transcriptMarkdownRowStyle,
            topChromeHeight: transcriptTopChromeHeight,
            onInitialPresentationReady: {
              isInitialTranscriptReady = true
            },
            onScrollViewReady: { scrollView in
              guard !isReadOnly else { return }
              focus.transcriptView = scrollView
              if let chatId = controller.serverSession?.id {
                focus.registerTranscript(scrollView, forChat: chatId)
              }
            }
          )
          .ignoresSafeArea(.container, edges: transcriptTopChromeHeight > 0 ? .top : [])
        }
      }
    }
  }

  var hasOlderHistory: Bool { controller.hasOlderHistory(presentingBotConversation: presentsBotConversation) }

  var isLoadingOlderHistory: Bool {
    controller.isLoadingOlderHistory(presentingBotConversation: presentsBotConversation)
  }

  @discardableResult
  func requestOlderHistoryLoad() -> Bool {
    guard historyLoadTask == nil, hasOlderHistory, !isLoadingOlderHistory else { return false }
    historyLoadTask = Task { @MainActor in
      defer { historyLoadTask = nil }
      await controller.loadOlderHistory(presentingBotConversation: presentsBotConversation)
    }
    return true
  }

  func connectForReading() async {
    guard !AppPreview.isRunning else { return }
    await controller.connectIfNeeded()
  }

  func submitProjection() {
    guard let request = mountedProjectionRequest else { return }
    if projectedSessionID != request.key.sessionID {
      resetProjection(for: request.key.sessionID)
    }
    projectionWorker.submit(request, input: controller.transcriptProjectionInput) { output in
      publishProjection(output)
    }
  }

  private func resetProjection(for sessionID: UUID) {
    projectedRows = []
    projectedRowsVersion &+= 1
    projectedSessionID = sessionID
    projectionPublication.reset()
  }

  private func publishProjection(_ output: TranscriptSettledProjectionWorker.Output) {
    guard output.request.key.sessionID == projectedSessionID else { return }
    projectedRows = output.rows
    projectedRowsVersion &+= 1
    projectionPublication.publish(output.request)
  }

  var transcriptMarkdownTheme: MarkdownTheme {
    makeMarkdownTheme(highlight: codeHighlightTheme.map { ($0.key, $0.json) })
  }

  var transcriptMarkdownRowStyle: TranscriptMarkdownRowStyle {
    TranscriptMarkdownRowStyle(markdown: transcriptMarkdownTheme)
  }

  var transcriptLayoutFingerprint: Int {
    var hasher = Hasher()
    hasher.combine(dynamicTypeSize)
    hasher.combine(transcriptMarkdownTheme.renderFingerprint)
    return hasher.finalize()
  }

  var transcriptProjectionRequest: TranscriptProjectionRequest {
    TranscriptProjectionRequest(
      key: controller.transcriptProjectionKey,
      options: .init(
        includesConnectingRow: false,
        bottomSpacerHeight: composerHeight + 24,
        presentsBotConversation: presentsBotConversation
      )
    )
  }

  var isPreparingTranscript: Bool {
    projectionPublication.isPending(currentRequest: transcriptProjectionRequest)
  }
}

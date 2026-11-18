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

  func revealRequestedQuote() {
    guard let request = controller.quoteRevealRequest else { return }

    controller.quoteRevealRequest = nil
    let revealer = TranscriptQuoteRevealer(
      controller: controller,
      target: presentationSurface.ensureScrollView(),
      presentsBotConversation: presentsBotConversation
    )
    Task { await revealer.reveal(request.quote) }
  }

  private func revealToolCall(_ toolCallId: String) async {
    guard let location = await controller.workedItemLocation(ofToolCall: toolCallId) else { return }

    TranscriptWorkedItemReveal.expand(location, in: controller.disclosure)
    presentationSurface.ensureScrollView().reveal(location)
  }

  var transcriptImageActions: MarkdownImageActions {
    TranscriptMarkdownImageOpener.actions(
      quickLook: quickLook, attachmentImages: attachmentImages, openDocument: openFileDocument,
      quoteActions: TranscriptQuoteActions(controller: controller))
  }

  var transcriptSurface: some View {
    ZStack {
      Color.clear
      if isTranscriptMounted || (reusesChatPage && transcriptMount.hasMounted) {
        ActiveTranscriptProjectionScope(
          controller: controller,
          projectedRows: projection.rows,
          projection: presentationSurface.activeProjection
        ) {
          activeRows, activeRowsVersion, isActiveProjectionPending, isAwaitingFirstActiveProjection,
          activeTextRestorationID in
          let visibleRows = presentationSurface.workedRowsVisibility.presentSettled(
            projection.rows,
            sourceVersion: projection.rowsVersion,
            disclosure: controller.disclosure
          )
          let visibleActiveRows = TranscriptWorkedRowsVisibility.present(activeRows, disclosure: controller.disclosure)
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
                sourceRevision: projection.rowsVersion,
                visibilityRevision: visibleRows.visibilityRevision
              ),
              projectionRevision: projection.rowsVersion,
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
                    .environment(environment)
                    .environment(\.attachmentImages, attachmentImages)
                    .environment(\.openFileDocument, openFileDocument)
                    .environment(\.openSubagent, openSubagent)
                    .environment(\.hoverTrackingSuspended, controller.isSending)
                    .environment(\.userBubbleStyle, presentsBotConversation ? .accent : .standard)
                    .environment(\.transcriptDisclosure, controller.disclosure)
                    .environment(\.transcriptController, controller)
                    .environment(
                      \.pluginAppHost,
                      PluginAppHost(
                        environment: environment, session: controller,
                        presenter: presentsBotConversation ? nil : pluginAppPresenter)
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
            addToChatShortcut: ShortcutCatalog.addToChatShortcut,
            keepsSurfacesAside: reusesChatPage,
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

    projection.submit(request, input: controller.transcriptProjectionInput)
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
    projection.isPending(currentRequest: transcriptProjectionRequest)
  }
}

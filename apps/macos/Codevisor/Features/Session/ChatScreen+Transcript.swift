import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

extension ChatScreen {
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
          let visibleActiveRows = TranscriptWorkedRowsVisibility.present(
            activeRows,
            disclosure: controller.disclosure,
            activeItem: controller.activeItem
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
              hasOlderHistory: controller.hasOlderHistory,
              showsOlderHistoryLoadingIndicator: controller.isLoadingOlderHistory,
              isLoadingInitialHistory: controller.isLoadingInitialHistory,
              isPreparingInitialProjection: isPreparingTranscript,
              isActiveProjectionPending: isActiveProjectionPending,
              isAwaitingFirstActiveProjection: isAwaitingFirstActiveProjection,
              activeTextRestorationID: activeTextRestorationID,
              layoutFingerprint: transcriptLayoutFingerprint,
              scrollCommand: scrollCommand,
              sendAnimationRequest: controller.userSendAnimationRequest,
              textAnimationRegistry: presentationSurface.textAnimationRegistry,
              allowsLiveTextAnimation: presentationSurface.textAnimationVisibility.isVisible,
              reduceMotion: reduceMotion
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
                    .environment(\.attachmentImages, attachmentImages)
                    .environment(\.openFileDocument, openFileDocument)
                    .environment(\.openSubagent, openSubagent)
                    .environment(\.hoverTrackingSuspended, controller.isSending)
                    .environment(\.transcriptDisclosure, controller.disclosure)
                    .environment(\.transcriptController, controller)
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
              markdownImageLoader: attachmentImages?.markdownImageLoader,
              openMarkdownLink: { url in
                TranscriptMarkdownLinkOpener.open(
                  url, quickLook: quickLook, attachmentImages: attachmentImages,
                  openDocument: openFileDocument)
              },
              markdownImageActions: transcriptImageActions
            ),
            markdownRowStyle: transcriptMarkdownRowStyle,
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
        }
      }
    }
  }

  @discardableResult
  func requestOlderHistoryLoad() -> Bool {
    guard historyLoadTask == nil, controller.hasOlderHistory,
      !controller.isLoadingOlderHistory
    else { return false }
    historyLoadTask = Task { @MainActor in
      defer { historyLoadTask = nil }
      await controller.loadOlderHistory()
    }
    return true
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
        bottomSpacerHeight: composerHeight + 24
      )
    )
  }

  var isPreparingTranscript: Bool {
    projectionPublication.isPending(currentRequest: transcriptProjectionRequest)
  }
}

import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

// MARK: - Transcript

extension ChatScreen {
  /// Inline images preview in Quick Look; their menu opens a tab or copies.
  var transcriptImageActions: MarkdownImageActions {
    TranscriptMarkdownImageOpener.actions(
      quickLook: quickLook, attachmentImages: attachmentImages, openDocument: openFileDocument)
  }

  var transcriptSurface: some View {
    ZStack {
      theme.contentBackground
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
            disclosure: controller.disclosure,
            runningSubagentToolCallIDs: controller.runningSubagentToolCallIds
          )
          let visibleActiveRows = TranscriptWorkedRowsVisibility.present(
            activeRows,
            disclosure: controller.disclosure,
            activeItem: controller.activeItem,
            runningSubagentToolCallIDs: controller.runningSubagentToolCallIds
          )
          NativeTranscriptView(
            presentationSurface: presentationSurface,
            input: TranscriptSurfaceInput(
              sessionController: controller,
              rows: visibleRows.rows,
              activeRows: visibleActiveRows.rows,
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
                    .environment(\.theme, theme)
                    .environment(\.attachmentImages, attachmentImages)
                    .environment(\.openFileDocument, openFileDocument)
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
                // AppKit can publish a transient edge and its corrected final
                // edge during one layout pass. Defer the SwiftUI mutation, but
                // preserve every callback in order so the final geometry wins.
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
              focus.transcriptView = scrollView
              // Keyed: EVERY chat's transcript is a click-to-blur zone in
              // multi-chat workspaces (the single slot is last-mounted).
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
    makeMarkdownTheme(
      theme: theme,
      highlight: codeHighlightTheme.map { ($0.key, $0.json) }
    )
  }

  var transcriptMarkdownRowStyle: TranscriptMarkdownRowStyle {
    TranscriptMarkdownRowStyle(
      markdown: transcriptMarkdownTheme,
      appTheme: theme
    )
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

import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import UIKit

extension SessionTranscriptView {
  var transcriptImageActions: MarkdownImageActions {
    TranscriptMarkdownImageOpener.actions(
      quickLook: quickLook, attachmentImages: attachmentImages, openDocument: openFileDocument)
  }

  func openMarkdownLink(_ url: URL) -> Bool {
    TranscriptMarkdownLinkOpener.open(
      url, quickLook: quickLook, attachmentImages: attachmentImages, openDocument: openFileDocument)
  }

  var transcript: some View {
    return ActiveTranscriptProjectionScope(
      controller: controller,
      projectedRows: projectedRows
    ) {
      activeRows, activeRowsVersion, isActiveProjectionPending, isAwaitingFirstActiveProjection,
      activeTextRestorationID in
      let visibleRows = workedRowsVisibilityCache.presentSettled(
        projectedRows,
        sourceVersion: projectedRowsVersion,
        disclosure: disclosure
      )
      let visibleActiveRows = TranscriptWorkedRowsVisibility.presentActive(
        activeRows,
        disclosure: disclosure,
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
          followsLatest: followsLatest,
          hasOlderHistory: controller.hasOlderPresentedHistory,
          showsOlderHistoryLoadingIndicator: presentationRole == .foreground
            && olderHistoryPresentation.isPresented,
          olderHistoryPresentationTarget: olderHistoryPresentation.presentationTarget,
          isLoadingInitialHistory: controller.isLoadingInitialHistory,
          isPreparingInitialProjection: isPreparingTranscript,
          isActiveProjectionPending: isActiveProjectionPending,
          isAwaitingFirstActiveProjection: isAwaitingFirstActiveProjection,
          activeTextRestorationID: activeTextRestorationID,
          layoutFingerprint: transcriptLayoutFingerprint,
          scrollCommand: scrollCommand,
          sendAnimationRequest: controller.userSendAnimationRequest,
          sendAnimationSourceFrame: sendAnimationSourceFrame,
          presentationRole: presentationRole,
          textAnimationRegistry: textAnimationRegistry,
          allowsLiveTextAnimation: textAnimationVisibility.isVisible,
          reduceMotion: reduceMotion,
          scrollIndicatorBottomInset: transcriptBottomObstruction + 6,
          topContentClearance: topContentClearance
        ),
        callbacks: TranscriptSurfaceCallbacks(
          claimSendAnimation: { request in
            controller.claimUserSendAnimation(request)
          },
          rowContent: { row in
            AnyView(
              TranscriptRowContentView(
                row: row, controller: controller, leaves: .iOS(controller: controller)
              )
              .reportsStreamingTextAnimationActivity()
              .environment(\.attachmentImages, attachmentImages)
              .environment(\.quickLook, quickLook)
              .environment(\.openFileDocument, openFileDocument)
              .environment(\.openSubagent, openSubagent)
              .markdownImageActions(transcriptImageActions)
              .environment(\.transcriptDisclosure, disclosure)
              .environment(\.transcriptController, controller)
              .environment(\.userBubbleStyle, userBubbleStyle)
              .environment(
                \.streamingTextAnimationVisibility,
                textAnimationVisibility
              )
              .environment(
                \.streamingTextAnimationRegistry,
                textAnimationRegistry
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
            DispatchQueue.main.async {
              olderHistoryPresentation.didPresent(token: token)
            }
          },
          onSendAnimationCompleted: { request in
            onSendAnimationCompleted?(request)
          },
          openMarkdownLink: openMarkdownLink,
          markdownImageActions: transcriptImageActions,
          onSendAnimationStarted: { request in
            onSendAnimationStarted?(request)
            Task { @MainActor in
              await Task.yield()
              sendAnimationsStarted &+= 1
            }
          },
          onEarlierHistoryCollapseChange: { collapse in
            DispatchQueue.main.async {
              if earlierHistoryCollapse != collapse { earlierHistoryCollapse = collapse }
            }
          }
        )
      )
    }
    .ignoresSafeArea(.container, edges: [.top, .bottom])
    .onChange(of: controller.userSendSignal) { _, _ in
      followsLatest = true
      scrollCommand.token &+= 1
    }
  }

  var transcriptProjectionRequest: TranscriptProjectionRequest {
    TranscriptProjectionRequest(
      key: controller.transcriptProjectionKey,
      options: .init(
        includesConnectingRow: true,
        bottomSpacerHeight: transcriptBottomObstruction + Self.transcriptBottomBreathingRoom,
        presentsBotConversation: controller.presentsBotConversation
      )
    )
  }

  var isPreparingTranscript: Bool {
    projectionPublication.isPending(currentRequest: transcriptProjectionRequest)
  }

  @discardableResult
  func requestOlderHistoryLoad() -> Bool {
    guard historyLoadTask == nil, controller.hasOlderPresentedHistory,
      !controller.isLoadingOlderPresentedHistory
    else { return false }
    guard
      let token = olderHistoryPresentation.begin(
        hasOlderHistory: controller.hasOlderPresentedHistory
      )
    else { return false }
    historyLoadTask = Task { @MainActor in
      defer { historyLoadTask = nil }
      let insertedItemCount = await controller.loadOlderPresentedHistory()
      guard !Task.isCancelled else {
        olderHistoryPresentation.cancel(token: token)
        return
      }
      olderHistoryPresentation.requestDidFinish(
        token: token,
        insertedItemCount: insertedItemCount,
        requiredProjectionKey: insertedItemCount > 0
          ? controller.transcriptProjectionKey
          : nil
      )
      if let publishedRequest = projectionPublication.publishedRequest {
        olderHistoryPresentation.projectionDidPublish(
          key: publishedRequest.key,
          revision: projectedRowsVersion
        )
      }
    }
    return true
  }

  var transcriptLayoutFingerprint: Int {
    var hasher = Hasher()
    hasher.combine(dynamicTypeSize)
    hasher.combine(displayScale)
    hasher.combine(markdownTheme.renderFingerprint)
    if composerTextEditorHandoffRole == .promotionSource, let composerTextEditorHandoffID {
      hasher.combine(composerTextEditorHandoffID)
    } else if let layoutNamespaceToken {
      hasher.combine(layoutNamespaceToken)
    } else {
      hasher.combine(controller.previewCacheNamespace)
    }
    hasher.combine(Self.transcriptMeasurementSchemaVersion)
    return hasher.finalize()
  }
}

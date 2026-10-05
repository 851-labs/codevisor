import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import UIKit

// MARK: - Transcript

extension SessionTranscriptView {
  /// Inline images preview in Quick Look; their menu opens a tab or copies.
  var transcriptImageActions: MarkdownImageActions {
    TranscriptMarkdownImageOpener.actions(
      quickLook: quickLook, attachmentImages: attachmentImages, openDocument: openFileDocument)
  }

  /// Opens a linked workspace file as a document tab, or in Quick Look when
  /// no tab can host it; web links fall through to the platform.
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
        disclosure: disclosure,
        runningSubagentRunToolCallIDs: controller.runningSubagentRunToolCallIds
      )
      let visibleActiveRows = TranscriptWorkedRowsVisibility.present(
        activeRows,
        disclosure: disclosure,
        activeItem: controller.activeItem,
        runningSubagentRunToolCallIDs: controller.runningSubagentRunToolCallIds
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
          followsLatest: followsLatest,
          hasOlderHistory: controller.hasOlderHistory,
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
          scrollIndicatorBottomInset: transcriptBottomObstruction + 6
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
              .environment(\.theme, theme)
              .environment(\.attachmentImages, attachmentImages)
              .environment(\.quickLook, quickLook)
              .environment(\.openFileDocument, openFileDocument)
              .environment(\.openSubagent, openSubagent)
              .markdownImageActions(transcriptImageActions)
              .environment(\.transcriptDisclosure, disclosure)
              .environment(\.transcriptController, controller)
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
              .environment(
                \.runningSubagentRunToolCallIds,
                controller.runningSubagentRunToolCallIds
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
          },
          onSendAnimationCompleted: { request in
            onSendAnimationCompleted?(request)
          },
          openMarkdownLink: openMarkdownLink,
          markdownImageActions: transcriptImageActions,
          onSendAnimationStarted: { onSendAnimationStarted?($0) }
        )
      )
    }
    // Match SwiftUI.ScrollView's navigation behavior: the scroll surface
    // reaches beneath the translucent top bar, while its UIKit content
    // inset keeps the first resting row below that chrome. It also runs
    // to the bottom of the screen, under the floating glass composer and
    // the home indicator; the bottom spacer (see
    // `transcriptBottomObstruction`) keeps the newest row above both.
    // The keyboard still bounds it, since the keyboard is opaque.
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
        bottomSpacerHeight: transcriptBottomObstruction + Self.transcriptBottomBreathingRoom
      )
    )
  }

  var isPreparingTranscript: Bool {
    projectionPublication.isPending(currentRequest: transcriptProjectionRequest)
  }

  @discardableResult
  func requestOlderHistoryLoad() -> Bool {
    guard historyLoadTask == nil, controller.hasOlderHistory,
      !controller.isLoadingOlderHistory
    else { return false }
    guard
      let token = olderHistoryPresentation.begin(
        hasOlderHistory: controller.hasOlderHistory
      )
    else { return false }
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
      // This sheet has its own short-lived measurement cache. Adopting a
      // workspace changes its file namespace, not the bubble's geometry;
      // invalidating here would cut the first send short. The destination
      // uses the authoritative file namespace in its separate cache.
      hasher.combine(composerTextEditorHandoffID)
    } else if let layoutNamespaceToken {
      // An in-place draft: same reasoning as the sheet above. The token
      // drops once the route becomes the workspace, after the send lands.
      hasher.combine(layoutNamespaceToken)
    } else {
      hasher.combine(controller.previewCacheNamespace)
    }
    hasher.combine(Self.transcriptMeasurementSchemaVersion)
    return hasher.finalize()
  }
}

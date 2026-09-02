import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import UIKit

// MARK: - Transcript

extension SessionTranscriptView {
  /// Shows a linked workspace file in Quick Look; web links fall through
  /// to the platform.
  func openMarkdownLink(_ url: URL) -> Bool {
    guard let file = markdownLinkPreviewFile(url) else { return false }
    guard let attachmentImages else { return true }
    Task {
      guard let url = await materializeQuickLookURL(for: file, store: attachmentImages) else {
        return
      }
      linkedQuickLookURL = QuickLookURL(url: url)
    }
    return true
  }

  var transcript: some View {
    return ActiveTranscriptProjectionScope(
      controller: controller,
      projectedRows: projectedRows
    ) { activeRows, activeRowsVersion, isActiveProjectionPending, isAwaitingFirstActiveProjection in
      let visibleRows = workedRowsVisibilityCache.presentSettled(
        projectedRows,
        sourceVersion: projectedRowsVersion,
        disclosure: disclosure,
        runningSubagentToolCallIDs: controller.runningSubagentToolCallIds
      )
      let visibleActiveRows = TranscriptWorkedRowsVisibility.present(
        activeRows,
        disclosure: disclosure,
        activeItem: controller.activeItem,
        runningSubagentToolCallIDs: controller.runningSubagentToolCallIds
      )
      NativeTranscriptView(
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
          layoutFingerprint: transcriptLayoutFingerprint,
          scrollCommand: scrollCommand,
          sendAnimationRequest: controller.userSendAnimationRequest,
          sendAnimationSourceFrame: sendAnimationSourceFrame,
          presentationRole: presentationRole,
          textAnimationRegistry: textAnimationRegistry,
          reduceMotion: reduceMotion,
          scrollIndicatorBottomInset: composerHeight + 6
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
              .markdownLinkHandler(openMarkdownLink)
              .environment(\.theme, theme)
              .environment(\.attachmentImages, attachmentImages)
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
          onSendAnimationStarted: onSendAnimationStarted
        )
      )
    }
    // Match SwiftUI.ScrollView's navigation behavior: the scroll surface
    // reaches beneath the translucent top bar, while its UIKit content
    // inset keeps the first resting row below that chrome.
    .ignoresSafeArea(.container, edges: .top)
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
        bottomSpacerHeight: composerHeight + 24
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
    hasher.combine(Self.transcriptMeasurementSchemaVersion)
    return hasher.finalize()
  }
}

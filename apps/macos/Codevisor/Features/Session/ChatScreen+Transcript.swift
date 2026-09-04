import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

// MARK: - Transcript

extension ChatScreen {
  var transcriptSurface: some View {
    ZStack {
      theme.contentBackground
      if isTranscriptMounted {
        ActiveTranscriptProjectionScope(
          controller: controller,
          projectedRows: projectedRows
        ) { activeRows, activeRowsVersion, isActiveProjectionPending, isAwaitingFirstActiveProjection in
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
                        openDocument: openMarkdownDocument)
                    }
                    .environment(\.theme, theme)
                    .environment(\.attachmentImages, attachmentImages)
                    .environment(\.openMarkdownDocument, openMarkdownDocument)
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
              openMarkdownLink: { url in
                TranscriptMarkdownLinkOpener.open(
                  url, quickLook: quickLook, attachmentImages: attachmentImages,
                  openDocument: openMarkdownDocument)
              }
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
          .mask {
            ComposerTranscriptMask(
              composerSize: composerMaskSize,
              bottomInset: Self.composerBottomMargin
            )
          }
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

  var transcriptRows: [TranscriptVirtualRow] {
    var result: [TranscriptVirtualRow] = []
    let settled = controller.settledConversation
    let pendingMessage = controller.pendingUserMessage.flatMap { pending in
      settled.contains(where: { item in
        if case let .user(message) = item { return message.id == pending.id }
        return false
      }) ? nil : pending
    }
    let pendingIsOpeningRow = settled.isEmpty && !controller.hasActiveItem
    let waitingDescription = controller.waitingBackgroundTaskDescription
    let waitingAssistantID: UUID? = {
      guard !controller.hasActiveItem,
        waitingDescription != nil,
        case let .assistant(message)? = settled.last,
        message.turn.finalText != nil
      else { return nil }
      return message.id
    }()

    if settled.isEmpty, !controller.hasActiveItem {
      if let message = pendingMessage {
        let showsStartingAgent = controller.setupPhases.isEmpty
        result.append(
          .init(
            // The settled model adopts this exact id, so the native
            // virtualizer keeps one host — and one layer animation —
            // across the optimistic-to-settled handoff.
            id: .message(message.id),
            content: .optimistic(
              message,
              showsStartingAgent: showsStartingAgent
            ),
            estimatedHeight: 90,
            measurementRevision: Self.optimisticMeasurementRevision(
              for: message,
              showsStartingAgent: showsStartingAgent
            )
          ))
      }
      if !controller.setupPhases.isEmpty {
        result.append(
          .init(
            id: .setup,
            content: .setup(controller.setupPhases),
            estimatedHeight: 80
          ))
      }
    }

    for (index, item) in settled.enumerated() {
      if index == 0, case .assistant = item, !controller.setupPhases.isEmpty {
        result.append(
          .init(
            id: .setup,
            content: .setup(controller.setupPhases),
            estimatedHeight: 80
          ))
      }
      let itemWaitingDescription = item.id == waitingAssistantID ? waitingDescription : nil
      if case let .assistant(message) = item,
        let planDocument = message.turn.planDocument, !planDocument.isEmpty
      {
        let revision = Self.measurementRevision(
          for: item,
          waitingOnBackgroundTask: itemWaitingDescription
        )
        let hasPlanningRow =
          message.turn.hasDeferredWorkedDetails
          || !message.turn.workedItemsBeforePlan.isEmpty
        if hasPlanningRow {
          result.append(
            .init(
              id: .assistantPlanning(message.id),
              content: .assistantPlanning(message),
              estimatedHeight: 44,
              measurementRevision: revision
            ))
        }
        result.append(
          .init(
            id: .plan(message.id),
            content: .planDocument(planDocument),
            estimatedHeight: Self.estimatedPlanHeight(planDocument),
            measurementRevision: Self.planMeasurementRevision(planDocument)
          ))
        let hasResultRow =
          !message.turn.workedItemsAfterPlan.isEmpty
          || message.turn.finalText != nil
          || message.turn.stopDetail != nil
          || message.turn.isGenerating
        if hasResultRow {
          result.append(
            .init(
              id: .assistantResult(message.id),
              content: .assistantResult(
                message,
                waitingOnBackgroundTask: itemWaitingDescription
              ),
              estimatedHeight: 240,
              measurementRevision: revision
            ))
        }
      } else {
        result.append(
          .init(
            id: .message(item.id),
            content: .message(
              item,
              waitingOnBackgroundTask: itemWaitingDescription
            ),
            estimatedHeight: Self.estimatedHeight(for: item),
            measurementRevision: Self.measurementRevision(
              for: item,
              waitingOnBackgroundTask: itemWaitingDescription
            )
          ))
      }
      if index == 0, case .user = item, !controller.setupPhases.isEmpty {
        result.append(
          .init(
            id: .setup,
            content: .setup(controller.setupPhases),
            estimatedHeight: 80
          ))
      }
    }

    if settled.isEmpty, controller.hasActiveItem, !controller.setupPhases.isEmpty {
      result.append(
        .init(
          id: .setup,
          content: .setup(controller.setupPhases),
          estimatedHeight: 80
        ))
    }
    if let activeItem = controller.activeItem {
      result.append(
        .init(
          id: .active(activeItem.id),
          content: .active(activeItem),
          estimatedHeight: 320
        ))
    }
    if !pendingIsOpeningRow, let message = pendingMessage {
      result.append(
        .init(
          id: .message(message.id),
          content: .optimistic(message, showsStartingAgent: false),
          estimatedHeight: 90,
          measurementRevision: Self.optimisticMeasurementRevision(
            for: message,
            showsStartingAgent: false
          )
        ))
    }
    if let waitingDescription, waitingAssistantID == nil, !controller.hasActiveItem {
      result.append(
        .init(
          id: .backgroundTask,
          content: .backgroundTask(waitingDescription),
          estimatedHeight: 32
        ))
    }
    if let updatingHarnessName = controller.waitingHarnessUpdateName {
      // The user's prompt is queued server-side while the harness
      // updates — an honest, ephemeral marker that clears on release.
      result.append(
        .init(
          id: .updateGate,
          content: .updateGate(updatingHarnessName),
          estimatedHeight: 32
        ))
    }
    // Waiting for the server to come back (e.g. the managed server is
    // still booting right after an app update) is a loading state, not a
    // failure — the error banner only appears if the wait times out.
    if let serverWait = controller.serverWaitMessage {
      result.append(
        .init(
          id: .serverWait,
          content: .serverWait(serverWait),
          estimatedHeight: 32
        ))
    }
    if let error = controller.sessionErrorMessage {
      result.append(.init(id: .error, content: .error(error), estimatedHeight: 56))
    }
    // Failures land in the chat history, right where the turn they broke
    // would have appeared — not detached beneath the composer (HIG: show
    // errors close to where the problem occurred).
    if case let .failed(message) = controller.status, message != controller.sessionErrorMessage {
      result.append(.init(id: .statusError, content: .error(message), estimatedHeight: 56))
    }
    result.append(
      .init(
        id: .bottomSpacer,
        content: .bottomSpacer(max(1, composerHeight + 24)),
        estimatedHeight: max(1, composerHeight + 24)
      ))
    return result
  }

  static func estimatedHeight(for item: ConversationItem) -> CGFloat {
    switch item {
    case let .user(message):
      max(52, min(240, 48 + CGFloat(message.text.count / 72) * 18))
    case .assistant:
      320
    }
  }

  static func estimatedPlanHeight(_ markdown: String) -> CGFloat {
    max(120, min(640, 72 + CGFloat(markdown.utf8.count / 72) * 18))
  }

  static func planMeasurementRevision(_ markdown: String) -> Int {
    var hasher = Hasher()
    hasher.combine(markdown.utf8.count)
    return hasher.finalize()
  }

  /// Optimistic content may temporarily include the startup indicator below
  /// the user bubble. Give that presentation its own revision so the stable
  /// message id preserves the host without preserving a stale row height
  /// after the model adopts the message.
  static func optimisticMeasurementRevision(
    for message: UserMessage,
    showsStartingAgent: Bool
  ) -> Int {
    var hasher = Hasher()
    hasher.combine(2)
    hasher.combine(message.text.utf8.count)
    hasher.combine(message.attachments.count)
    for attachment in message.attachments {
      hasher.combine(attachment.id)
      hasher.combine(attachment.sizeBytes)
    }
    hasher.combine(showsStartingAgent)
    return hasher.finalize()
  }

  /// Does not walk large Markdown payloads: counts and the model's existing
  /// monotonic/fingerprint fields are enough to guard in-memory measurements.
  static func measurementRevision(
    for item: ConversationItem,
    waitingOnBackgroundTask: String?
  ) -> Int {
    var hasher = Hasher()
    switch item {
    case let .user(message):
      hasher.combine(0)
      hasher.combine(message.text.utf8.count)
      hasher.combine(message.attachments.count)
      for attachment in message.attachments {
        hasher.combine(attachment.id)
        hasher.combine(attachment.sizeBytes)
      }
    case let .assistant(message):
      let turn = message.turn
      hasher.combine(1)
      hasher.combine(turn.entries.count)
      hasher.combine(turn.isGenerating)
      hasher.combine(turn.detailRevision)
      hasher.combine(turn.hasDeferredWorkedDetails)
      hasher.combine(turn.contextCompactionStatus?.rawValue)
      hasher.combine(turn.planDocument?.utf8.count ?? 0)
      hasher.combine(turn.stopDetail?.utf8.count ?? 0)
      hasher.combine(turn.subagentActivityFingerprint)
      hasher.combine(turn.attachments.count)
      for attachment in turn.attachments {
        hasher.combine(attachment.id)
        hasher.combine(attachment.sizeBytes)
      }
    }
    hasher.combine(waitingOnBackgroundTask)
    return hasher.finalize()
  }
}

import CoreGraphics
import CodevisorProtocol
import Foundation
import MarkdownCore

public enum TranscriptBlockLifecycle: Sendable, Equatable {
  case receiving
  case settled
}

public enum TranscriptMarkdownContainer: Sendable, Equatable {
  case assistantResponse
  case assistantWorked
  case planDocument
}

public struct TranscriptAssistantAttachment: Sendable, Equatable {
  public let messageID: UUID
  public let sourceID: String
  public let ordinal: Int
  public let file: PreviewFile
  public let label: String
  public let lifecycle: TranscriptBlockLifecycle
}

public enum TranscriptAssistantChromeSlice: Sendable, Equatable {
  case activity
  case epilogue

  var layoutComponent: String {
    switch self {
    case .activity: "activity"
    case .epilogue: "epilogue"
    }
  }
}

extension AssistantMessage {
  /// The message as history presents it: the turn's outcome minus the
  /// failure copy and its action classification.
  func withoutStopDetail() -> AssistantMessage {
    guard turn.stopDetail != nil || turn.stopKind != nil else { return self }
    var copy = self
    copy.turn.stopDetail = nil
    copy.turn.stopKind = nil
    return copy
  }
}

enum TranscriptAssistantRowProjection {
  static func appendSettled(
    _ item: ConversationItem,
    waitingOnBackgroundTask: String?,
    presentsStopDetail: Bool = true,
    to rows: inout [TranscriptPresentationRow]
  ) {
    guard case let .assistant(original) = item else {
      rows.append(
        .init(
          id: .message(item.id),
          content: .message(item, waitingOnBackgroundTask: waitingOnBackgroundTask),
          estimatedHeight: estimatedHeight(for: item),
          measurementRevision: measurementRevision(
            for: item,
            waitingOnBackgroundTask: waitingOnBackgroundTask
          )
        ))
      return
    }

    // A failure is only actionable on the latest turn. Older stop details
    // are dropped before projection, so no row — block, chrome, or shell —
    // can render them.
    let message = presentsStopDetail ? original : original.withoutStopDetail()
    let presented = ConversationItem.assistant(message)
    let projectedContent = appendAssistantBlocks(
      message,
      waitingOnBackgroundTask: waitingOnBackgroundTask,
      lifecycle: .settled,
      to: &rows
    )
    if projectedContent || hasStopDetailWithoutAnswer(message) {
      // An error-only turn keeps the exact row identity it had while
      // active, so settling reuses its host and measurement instead of
      // remounting under the aggregate `message:` key.
      appendStopDetailEpilogueIfNeeded(
        message,
        waitingOnBackgroundTask: waitingOnBackgroundTask,
        lifecycle: .settled,
        to: &rows
      )
    } else if hasStopDetailWithoutAnswer(original) {
      // An older error-only turn has nothing left to show.
    } else {
      rows.append(
        .init(
          id: .message(item.id),
          content: .message(presented, waitingOnBackgroundTask: waitingOnBackgroundTask),
          estimatedHeight: estimatedHeight(for: presented),
          measurementRevision: measurementRevision(
            for: presented,
            waitingOnBackgroundTask: waitingOnBackgroundTask
          )
        ))
    }
  }

  /// The block rows shared by the settled and active projections: both
  /// worked sections, the plan document, and the final response. Returns
  /// whether anything was projected so each caller can choose its own
  /// fallback (the assistant shell when settled, the aggregate active row
  /// while live).
  @discardableResult
  static func appendAssistantBlocks(
    _ message: AssistantMessage,
    waitingOnBackgroundTask: String?,
    lifecycle: TranscriptBlockLifecycle,
    to rows: inout [TranscriptPresentationRow]
  ) -> Bool {
    var projectedContent = appendWorkedSection(
      message,
      kind: .planning,
      items: message.turn.workedItemsBeforePlan,
      showsTimer: message.turn.planBoundary == nil,
      allowsDeferred: true,
      lifecycle: lifecycle,
      to: &rows
    )
    if let planDocument = message.turn.planDocument, !planDocument.isEmpty {
      TranscriptPlanRowProjection.append(
        messageID: message.id,
        markdown: planDocument,
        lifecycle: lifecycle,
        to: &rows
      )
      projectedContent = true
      projectedContent =
        appendWorkedSection(
          message,
          kind: .implementation,
          items: message.turn.workedItemsAfterPlan,
          showsTimer: true,
          allowsDeferred: false,
          lifecycle: lifecycle,
          to: &rows
        ) || projectedContent
    }
    return appendAssistantResponse(
      message,
      waitingOnBackgroundTask: waitingOnBackgroundTask,
      lifecycle: lifecycle,
      to: &rows
    ) || projectedContent
  }

  static func appendStopDetailEpilogueIfNeeded(
    _ message: AssistantMessage,
    waitingOnBackgroundTask: String?,
    lifecycle: TranscriptBlockLifecycle,
    to rows: inout [TranscriptPresentationRow]
  ) {
    guard hasStopDetailWithoutAnswer(message) else { return }
    appendChrome(
      message,
      slice: .epilogue,
      waitingOnBackgroundTask: waitingOnBackgroundTask,
      lifecycle: lifecycle,
      to: &rows
    )
  }

  /// Splits a final response into independently measurable rows. Error-only
  /// and still-forming turns keep their ordinary assistant shell.
  @discardableResult
  static func appendAssistantResponse(
    _ message: AssistantMessage,
    waitingOnBackgroundTask: String?,
    lifecycle: TranscriptBlockLifecycle,
    to rows: inout [TranscriptPresentationRow]
  ) -> Bool {
    if appendImageGenerationResponse(
      message, waitingOnBackgroundTask: waitingOnBackgroundTask, lifecycle: lifecycle, to: &rows)
    {
      return true
    }
    guard let (entryID, markdown) = responseText(message.turn) else { return false }

    let segments = assistantMarkdownSegments(
      markdown,
      attachments: message.turn.attachments,
      includeServerPaths: true,
      includeUnreferencedAttachments: true
    )
    var responseRows: [TranscriptPresentationRow] = []
    var ordinal = 0
    let parser = MarkdownParser()
    for (segmentIndex, segment) in segments.enumerated() {
      let sourceID = "\(entryID):\(segmentIndex)"
      switch segment {
      case let .markdown(source):
        let blocks = parser.parse(source)
        let sourceOrdinal = ordinal
        for chunk in TranscriptMarkdownChunkProjection.chunks(from: blocks) {
          let chunkOrdinal = sourceOrdinal + chunk.firstOrdinal
          let projected = TranscriptMarkdownChunk(
            messageID: message.id,
            sourceID: sourceID,
            ordinal: chunkOrdinal,
            blocks: chunk.blocks,
            documentSource: source,
            lifecycle: lifecycle,
            container: .assistantResponse,
            fragment: chunk.fragment
          )
          responseRows.append(
            .init(
              id: markdownID(
                messageID: message.id,
                sourceID: sourceID,
                ordinal: chunkOrdinal,
                fragment: chunk.fragment?.identity,
                lifecycle: lifecycle
              ),
              content: .markdownChunk(projected),
              estimatedHeight: projected.estimatedHeight,
              measurementRevision: projected.measurementRevision,
              spacingAfter: chunk.fragment?.isLastInSourceBlock == false ? 0 : 10
            ))
        }
        ordinal += blocks.count
      case let .file(file, label):
        let attachment = TranscriptAssistantAttachment(
          messageID: message.id,
          sourceID: sourceID,
          ordinal: ordinal,
          file: file,
          label: label,
          lifecycle: lifecycle
        )
        responseRows.append(
          .init(
            id: attachmentID(
              messageID: message.id,
              sourceID: sourceID,
              ordinal: ordinal,
              lifecycle: lifecycle
            ),
            content: .assistantAttachment(attachment),
            estimatedHeight: 180,
            measurementRevision: attachmentMeasurementRevision(attachment),
            spacingAfter: 8
          ))
        ordinal += 1
      }
    }
    guard !responseRows.isEmpty else { return false }

    let last = responseRows.removeLast()
    responseRows.append(
      .init(
        id: last.id,
        content: last.content,
        estimatedHeight: last.estimatedHeight,
        measurementRevision: last.measurementRevision,
        spacingAfter: 14,
        finishedResponseItemId: last.finishedResponseItemId
      ))
    rows.append(contentsOf: responseRows)
    appendChrome(
      message,
      slice: .epilogue,
      waitingOnBackgroundTask: waitingOnBackgroundTask,
      lifecycle: lifecycle,
      to: &rows
    )
    return true
  }

  static func appendActivityIfNeeded(
    _ message: AssistantMessage,
    lifecycle: TranscriptBlockLifecycle,
    to rows: inout [TranscriptPresentationRow]
  ) {
    guard message.turn.isGenerating,
      message.turn.retryStatus != nil || message.turn.showsActivityIndicator
    else { return }
    appendChrome(
      message,
      slice: .activity,
      waitingOnBackgroundTask: nil,
      lifecycle: lifecycle,
      to: &rows
    )
  }

  private static func appendChrome(
    _ message: AssistantMessage,
    slice: TranscriptAssistantChromeSlice,
    waitingOnBackgroundTask: String?,
    lifecycle: TranscriptBlockLifecycle,
    to rows: inout [TranscriptPresentationRow]
  ) {
    rows.append(
      .init(
        id: chromeID(messageID: message.id, slice: slice, lifecycle: lifecycle),
        content: .assistantChrome(
          message,
          slice: slice,
          waitingOnBackgroundTask: waitingOnBackgroundTask
        ),
        estimatedHeight: 32,
        measurementRevision: measurementRevision(
          for: .assistant(message),
          waitingOnBackgroundTask: waitingOnBackgroundTask
        )
      ))
  }

  static func activeFallbackRow(
    for item: ConversationItem
  ) -> TranscriptPresentationRow {
    .init(
      id: .active(item.id),
      content: .active(item),
      estimatedHeight: activeFallbackEstimatedHeight(for: item)
    )
  }

  /// The outer projection briefly owns one aggregate active row while the
  /// block projection runs. A fresh turn has one known 32-point activity row;
  /// reserving a generic response height here would move the bottom-pinned
  /// transcript before the precise projection arrives.
  static func activeFallbackEstimatedHeight(for item: ConversationItem) -> CGFloat {
    guard case let .assistant(message) = item,
      message.turn.entries.isEmpty,
      message.turn.attachments.isEmpty,
      message.turn.subagents.isEmpty,
      message.turn.planDocument?.isEmpty != false,
      message.turn.retryStatus != nil || message.turn.showsActivityIndicator
    else { return 320 }
    return 32
  }

  static func planningID(
    messageID: UUID,
    lifecycle: TranscriptBlockLifecycle
  ) -> TranscriptPresentationRow.ID {
    switch lifecycle {
    case .receiving: .activePlanning(messageID)
    case .settled: .assistantPlanning(messageID)
    }
  }

  static func resultID(
    messageID: UUID,
    lifecycle: TranscriptBlockLifecycle
  ) -> TranscriptPresentationRow.ID {
    switch lifecycle {
    case .receiving: .activeResult(messageID)
    case .settled: .assistantResult(messageID)
    }
  }

  private static func chromeID(
    messageID: UUID,
    slice: TranscriptAssistantChromeSlice,
    lifecycle: TranscriptBlockLifecycle
  ) -> TranscriptPresentationRow.ID {
    switch lifecycle {
    case .receiving: .activeChrome(messageID, slice)
    case .settled: .assistantChrome(messageID, slice)
    }
  }

  static func markdownID(
    messageID: UUID,
    sourceID: String,
    ordinal: Int,
    fragment: String?,
    lifecycle: TranscriptBlockLifecycle
  ) -> TranscriptPresentationRow.ID {
    switch lifecycle {
    case .receiving:
      .activeMarkdown(
        messageID,
        sourceID: sourceID,
        ordinal: ordinal,
        fragment: fragment
      )
    case .settled:
      .assistantMarkdown(
        messageID,
        sourceID: sourceID,
        ordinal: ordinal,
        fragment: fragment
      )
    }
  }

  private static func attachmentID(
    messageID: UUID,
    sourceID: String,
    ordinal: Int,
    lifecycle: TranscriptBlockLifecycle
  ) -> TranscriptPresentationRow.ID {
    switch lifecycle {
    case .receiving: .activeAttachment(messageID, sourceID: sourceID, ordinal: ordinal)
    case .settled: .assistantAttachment(messageID, sourceID: sourceID, ordinal: ordinal)
    }
  }

  static func isUser(_ item: ConversationItem) -> Bool {
    if case .user = item { return true }
    return false
  }

  static func isAssistant(_ item: ConversationItem) -> Bool {
    if case .assistant = item { return true }
    return false
  }

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

  private static func attachmentMeasurementRevision(
    _ attachment: TranscriptAssistantAttachment
  ) -> Int {
    var hasher = Hasher()
    hasher.combine(attachment.file.id)
    hasher.combine(attachment.label)
    return hasher.finalize()
  }

  private static func estimatedHeight(for item: ConversationItem) -> CGFloat {
    switch item {
    case let .user(message):
      max(52, min(240, 48 + CGFloat(message.text.count / 72) * 18))
    case .assistant:
      320
    }
  }

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

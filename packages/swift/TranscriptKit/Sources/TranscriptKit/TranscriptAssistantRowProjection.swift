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
  func withoutStopDetail() -> AssistantMessage {
    guard turn.stopDetail != nil || turn.stopKind != nil else { return self }
    var copy = self
    copy.turn.stopDetail = nil
    copy.turn.stopKind = nil
    copy.turn.autoResume = nil
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
      if TranscriptForkRowProjection.append(item, to: &rows) { return }
      appendMessage(
        messageID: item.id, item: item, waitingOnBackgroundTask: waitingOnBackgroundTask, to: &rows
      )
      return
    }

    let message = presentsStopDetail ? original : original.withoutStopDetail()
    let presented = ConversationItem.assistant(message)
    let projectedContent = appendAssistantBlocks(
      message,
      waitingOnBackgroundTask: waitingOnBackgroundTask,
      lifecycle: .settled,
      to: &rows
    )
    if projectedContent || hasStopDetailWithoutAnswer(message) {
      appendStopDetailEpilogueIfNeeded(
        message,
        waitingOnBackgroundTask: waitingOnBackgroundTask,
        lifecycle: .settled,
        to: &rows
      )
    } else if !hasStopDetailWithoutAnswer(original) {
      appendMessage(
        messageID: item.id, item: presented, waitingOnBackgroundTask: waitingOnBackgroundTask, to: &rows
      )
    }
  }

  private static func appendMessage(
    messageID: UUID,
    item: ConversationItem,
    waitingOnBackgroundTask: String?,
    to rows: inout [TranscriptPresentationRow]
  ) {
    rows.append(
      .init(
        id: .message(messageID),
        content: .message(item, waitingOnBackgroundTask: waitingOnBackgroundTask),
        estimatedHeight: TranscriptMessageRowMetrics.estimatedHeight(for: item),
        measurementRevision: TranscriptMessageRowMetrics.measurementRevision(
          for: item,
          waitingOnBackgroundTask: waitingOnBackgroundTask
        )
      ))
  }

  @discardableResult
  static func appendAssistantBlocks(
    _ message: AssistantMessage,
    waitingOnBackgroundTask: String?,
    lifecycle: TranscriptBlockLifecycle,
    to rows: inout [TranscriptPresentationRow]
  ) -> Bool {
    var projectedContent = TranscriptWorkedSectionProjection.append(
      message,
      kind: .planning,
      items: message.turn.workedItemsBeforePlan,
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
        TranscriptWorkedSectionProjection.append(
          message,
          kind: .implementation,
          items: message.turn.workedItemsAfterPlan,
          lifecycle: lifecycle,
          to: &rows
        ) || projectedContent
    }
    projectedContent =
      TranscriptPluginAppRowProjection.append(message, lifecycle: lifecycle, to: &rows) || projectedContent
    projectedContent = TranscriptCompactionRowProjection.append(message, to: &rows) || projectedContent
    projectedContent =
      appendAssistantResponse(
        message,
        waitingOnBackgroundTask: waitingOnBackgroundTask,
        lifecycle: lifecycle,
        to: &rows
      ) || projectedContent
    for request in message.turn.setupRequests {
      rows.append(.setupRequest(request, inBotConversation: false))
    }
    let interactions = message.turn.interactions.shownInTranscript
    for interaction in interactions {
      rows.append(.interaction(interaction, inBotConversation: false))
    }
    return projectedContent || !message.turn.setupRequests.isEmpty || !interactions.isEmpty
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

  static func appendStopDetail(_ message: AssistantMessage, to rows: inout [TranscriptPresentationRow]) {
    appendChrome(message, slice: .epilogue, waitingOnBackgroundTask: nil, lifecycle: .settled, to: &rows)
  }

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
      includeUnreferencedAttachments: true,
      localImagesPendingCapture: message.turn.isGenerating
    )
    var responseRows: [TranscriptPresentationRow] = []
    var ordinal = 0
    for (segmentIndex, segment) in segments.enumerated() {
      let sourceID = "\(entryID):\(segmentIndex)"
      switch segment {
      case let .markdown(source):
        let blocks = TranscriptMarkdownParseCache.shared.parse(
          source, messageID: message.id, sourceID: sourceID
        )
        let sourceOrdinal = ordinal
        let chunks = TranscriptMarkdownChunkProjection.chunks(from: blocks)
        for (chunkIndex, chunk) in chunks.enumerated() {
          let chunkOrdinal = sourceOrdinal + chunk.firstOrdinal
          let projected = TranscriptMarkdownChunk(
            messageID: message.id,
            sourceID: sourceID,
            ordinal: chunkOrdinal,
            blocks: chunk.blocks,
            documentSource: source,
            lifecycle: lifecycle,
            container: .assistantResponse,
            animationSourceID: segmentIndex == 0 ? entryID : sourceID,
            fragment: chunk.fragment,
            precedingRole: chunk.precedingRole
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
              spacingAfter: chunkIndex == chunks.count - 1 ? 10 : 0
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
            measurementRevision: TranscriptMessageRowMetrics.attachmentMeasurementRevision(attachment),
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
        spacingAfter: 14
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
      message.turn.retryStatus != nil || message.turn.reservesActivitySlot
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
        estimatedHeight: TranscriptMessageRowMetrics.chromeEstimatedHeight(
          message, slice: slice, waitingOnBackgroundTask: waitingOnBackgroundTask),
        measurementRevision: TranscriptMessageRowMetrics.measurementRevision(
          for: .assistant(message),
          waitingOnBackgroundTask: waitingOnBackgroundTask
        ),
        spacingAfter: slice == .activity ? TranscriptWorkedSectionProjection.headerSpacingAfter : nil
      ))
  }

  static func activeFallbackRow(
    for item: ConversationItem
  ) -> TranscriptPresentationRow {
    .init(
      id: .active(item.id),
      content: .active(item),
      estimatedHeight: activeFallbackEstimatedHeight(for: item),
      spacingAfter: activeFallbackSpacingAfter(for: item)
    )
  }

  static func activeFallbackEstimatedHeight(for item: ConversationItem) -> CGFloat {
    isOpeningLine(item) ? activityRowEstimatedHeight : 320
  }

  static func activeFallbackSpacingAfter(for item: ConversationItem) -> CGFloat? {
    isOpeningLine(item) ? TranscriptWorkedSectionProjection.headerSpacingAfter : nil
  }

  private static func isOpeningLine(_ item: ConversationItem) -> Bool {
    guard case let .assistant(message) = item else { return false }
    return message.turn.entries.allSatisfy(\.isBlankText)
      && message.turn.attachments.isEmpty
      && message.turn.subagents.isEmpty
      && message.turn.planDocument?.isEmpty != false
      && (message.turn.retryStatus != nil || message.turn.showsActivityIndicator)
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

  static let activityRowEstimatedHeight: CGFloat = 32

  static func hasStopDetailWithoutAnswer(_ message: AssistantMessage) -> Bool {
    !message.turn.isGenerating
      && message.turn.finalText == nil
      && message.turn.attachments.isEmpty
      && message.turn.generatedImageActivity.isEmpty
      && message.turn.stopDetail != nil
  }

  static func appendImageGenerationResponse(
    _ message: AssistantMessage,
    waitingOnBackgroundTask: String?,
    lifecycle: TranscriptBlockLifecycle,
    to rows: inout [TranscriptPresentationRow]
  ) -> Bool {
    guard !message.turn.generatedImageActivity.isEmpty else { return false }
    rows.append(
      .init(
        id: resultID(messageID: message.id, lifecycle: lifecycle),
        content: .assistantResult(message, waitingOnBackgroundTask: waitingOnBackgroundTask),
        estimatedHeight: 200,
        measurementRevision: TranscriptMessageRowMetrics.measurementRevision(
          for: .assistant(message), waitingOnBackgroundTask: waitingOnBackgroundTask)
      ))
    return true
  }

  static func responseText(_ turn: AssistantTurn) -> (String, String)? {
    if case let .text(id, text)? = turn.finalText { return (id, text) }
    return turn.attachments.isEmpty ? nil : ("attachments", "")
  }
}

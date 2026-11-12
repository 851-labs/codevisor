import CoreGraphics
import Foundation
import MarkdownCore

enum TranscriptWorkedSectionProjection {
  static let headerSpacingAfter: CGFloat = 12
  static let lastLineSpacingAfter: CGFloat = 12

  @discardableResult
  static func append(
    _ message: AssistantMessage,
    kind: TranscriptWorkedSectionKind,
    items: [WorkedItem],
    lifecycle: TranscriptBlockLifecycle,
    to rows: inout [TranscriptPresentationRow]
  ) -> Bool {
    let deferredDetailID =
      message.turn.defersWorkedSection(kind)
      ? message.turn.deferredDetailItemId
      : nil
    guard
      !items.isEmpty || deferredDetailID != nil || message.turn.showsLiveWorkedHeader(kind)
        || message.turn.showsWorkedHeaderWithoutWork(kind)
    else { return false }

    let identity = TranscriptWorkedSectionIdentity(messageID: message.id, kind: kind)
    appendHeader(message, kind: kind, items: items, lifecycle: lifecycle, identity: identity, to: &rows)

    if deferredDetailID != nil {
      return true
    }

    appendItems(message, kind: kind, items: items, lifecycle: lifecycle, identity: identity, to: &rows)
    return true
  }

  private static func appendHeader(
    _ message: AssistantMessage,
    kind: TranscriptWorkedSectionKind,
    items: [WorkedItem],
    lifecycle: TranscriptBlockLifecycle,
    identity: TranscriptWorkedSectionIdentity,
    to rows: inout [TranscriptPresentationRow]
  ) {
    let header = TranscriptWorkedSectionHeader(message: message, kind: kind, items: items)
    rows.append(
      .init(
        id: workedHeaderID(
          messageID: message.id,
          section: kind,
          lifecycle: lifecycle
        ),
        content: .workedHeader(header),
        estimatedHeight: 18,
        measurementRevision: settledMeasurementRevision(of: message, lifecycle: lifecycle) ?? 0,
        spacingAfter: headerSpacingAfter,
        workedSection: .init(
          identity: identity,
          role: .header(defaultExpanded: false, isFixedExpanded: header.isWorking)
        )
      ))
  }

  static func settledMeasurementRevision(
    of message: AssistantMessage,
    lifecycle: TranscriptBlockLifecycle
  ) -> Int? {
    guard lifecycle == .settled else { return nil }

    return TranscriptMessageRowMetrics.measurementRevision(for: .assistant(message), waitingOnBackgroundTask: nil)
  }

  private static func appendItems(
    _ message: AssistantMessage,
    kind: TranscriptWorkedSectionKind,
    items: [WorkedItem],
    lifecycle: TranscriptBlockLifecycle,
    identity: TranscriptWorkedSectionIdentity,
    to rows: inout [TranscriptPresentationRow]
  ) {
    let hasThinking = lifecycle == .receiving && message.turn.showsWorkedThinkingLine(kind)
    let earlierCount = items.earlierHistoryCount
    let lines = TranscriptWorkedLineRowBuilder(message: message, kind: kind, lifecycle: lifecycle, identity: identity)
    if earlierCount > 0 {
      rows.append(lines.earlierHistoryToggle(count: earlierCount))
    }
    for (index, item) in items.enumerated() {
      let isFirst = index == 0
      let isLast = index == items.count - 1 && !hasThinking
      let role: TranscriptWorkedSectionRowRole = index < earlierCount ? .earlierHistory : .content
      if case let .text(entryID, markdown) = item {
        appendMarkdown(
          message, kind: kind, entryID: entryID, markdown: markdown,
          isFirst: isFirst, isLast: isLast,
          lifecycle: lifecycle, identity: identity, role: role, to: &rows)
      } else {
        rows.append(lines.item(item, isFirst: isFirst, isLast: isLast, role: role))
      }
    }
    if hasThinking {
      rows.append(lines.thinking(isFirst: items.isEmpty))
    }
  }

  private static func appendMarkdown(
    _ message: AssistantMessage,
    kind: TranscriptWorkedSectionKind,
    entryID: String,
    markdown: String,
    isFirst: Bool,
    isLast: Bool,
    lifecycle: TranscriptBlockLifecycle,
    identity: TranscriptWorkedSectionIdentity,
    role: TranscriptWorkedSectionRowRole,
    to rows: inout [TranscriptPresentationRow]
  ) {
    let sourceID = "worked:\(kind.layoutComponent):\(entryID)"
    let blocks = TranscriptMarkdownParseCache.shared.parse(
      markdown, messageID: message.id, sourceID: sourceID, isReceiving: lifecycle == .receiving
    )
    let chunks = TranscriptMarkdownChunkProjection.chunks(from: blocks)
    for (chunkIndex, chunk) in chunks.enumerated() {
      let startsLine = chunkIndex == 0
      let endsLine = chunkIndex == chunks.count - 1
      let projected = TranscriptMarkdownChunk(
        messageID: message.id,
        sourceID: sourceID,
        ordinal: chunk.firstOrdinal,
        blocks: chunk.blocks,
        documentSource: markdown,
        lifecycle: lifecycle,
        container: .assistantWorked,
        animationSourceID: entryID,
        fragment: chunk.fragment,
        precedingRole: chunk.precedingRole,
        timeline: TranscriptTimelineMarks(
          startsLine: startsLine,
          endsLine: endsLine,
          railAbove: !(isFirst && startsLine),
          railBelow: !(isLast && endsLine)
        )
      )
      rows.append(
        .init(
          id: TranscriptAssistantRowProjection.markdownID(
            messageID: message.id,
            sourceID: sourceID,
            ordinal: chunk.firstOrdinal,
            fragment: chunk.fragment?.identity,
            lifecycle: lifecycle
          ),
          content: .markdownChunk(projected),
          estimatedHeight: projected.estimatedHeight,
          measurementRevision: projected.measurementRevision,
          spacingAfter: isLast && endsLine ? lastLineSpacingAfter : 0,
          workedSection: .init(identity: identity, role: role)
        ))
    }
  }

  private static func workedHeaderID(
    messageID: UUID,
    section: TranscriptWorkedSectionKind,
    lifecycle: TranscriptBlockLifecycle
  ) -> TranscriptPresentationRow.ID {
    switch lifecycle {
    case .receiving: .activeWorkedHeader(messageID, section)
    case .settled: .assistantWorkedHeader(messageID, section)
    }
  }
}

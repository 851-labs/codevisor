import CoreGraphics
import Foundation
import MarkdownCore

enum TranscriptWorkedSectionProjection {
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
    guard !items.isEmpty || deferredDetailID != nil || message.turn.showsLiveWorkedHeader(kind)
    else { return false }

    let identity = TranscriptWorkedSectionIdentity(messageID: message.id, kind: kind)
    appendHeader(message, kind: kind, lifecycle: lifecycle, identity: identity, to: &rows)

    // Deferred history starts loading from the header indicator. Until
    // hydration completes there is deliberately no content row: opening
    // changes neither document geometry nor the header's line height.
    if deferredDetailID != nil {
      return true
    }

    appendItems(message, kind: kind, items: items, lifecycle: lifecycle, identity: identity, to: &rows)
    return true
  }

  private static func appendHeader(
    _ message: AssistantMessage,
    kind: TranscriptWorkedSectionKind,
    lifecycle: TranscriptBlockLifecycle,
    identity: TranscriptWorkedSectionIdentity,
    to rows: inout [TranscriptPresentationRow]
  ) {
    rows.append(
      .init(
        id: workedHeaderID(
          messageID: message.id,
          section: kind,
          lifecycle: lifecycle
        ),
        content: workedHeaderContent(
          message: message,
          kind: kind,
          lifecycle: lifecycle
        ),
        estimatedHeight: 18,
        measurementRevision: TranscriptAssistantRowProjection.measurementRevision(
          for: .assistant(message),
          waitingOnBackgroundTask: nil
        ),
        spacingAfter: 12,
        workedSection: .init(
          identity: identity,
          // Collapsed by default, live or not: a live header rolls up
          // what the turn is doing in its own label.
          role: .header(defaultExpanded: false, isFixedExpanded: false)
        )
      ))
  }

  private static func appendItems(
    _ message: AssistantMessage,
    kind: TranscriptWorkedSectionKind,
    items: [WorkedItem],
    lifecycle: TranscriptBlockLifecycle,
    identity: TranscriptWorkedSectionIdentity,
    to rows: inout [TranscriptPresentationRow]
  ) {
    // Each item is a line on the section's timeline. Its rows abut so their
    // rails join into one line; a note keeps its virtualized Markdown rows.
    for (index, item) in items.enumerated() {
      let isFirst = index == 0
      let isLast = index == items.count - 1
      if case let .text(entryID, markdown) = item {
        appendMarkdown(
          message, kind: kind, entryID: entryID, markdown: markdown,
          isFirst: isFirst, isLast: isLast,
          lifecycle: lifecycle, identity: identity, to: &rows)
      } else {
        appendWorkedItemRow(
          message, kind: kind, itemID: item.id, estimatedHeight: 26,
          lifecycle: lifecycle, identity: identity,
          spacingAfter: isLast ? 12 : 0, to: &rows)
      }
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
    to rows: inout [TranscriptPresentationRow]
  ) {
    let sourceID = "worked:\(kind.layoutComponent):\(entryID)"
    let blocks = TranscriptMarkdownParseCache.shared.parse(
      markdown, messageID: message.id, sourceID: sourceID
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
          spacingAfter: isLast && endsLine ? 12 : 0,
          workedSection: .init(identity: identity, role: .content)
        ))
    }
  }

  private static func appendWorkedItemRow(
    _ message: AssistantMessage,
    kind: TranscriptWorkedSectionKind,
    itemID: String,
    estimatedHeight: CGFloat,
    lifecycle: TranscriptBlockLifecycle,
    identity: TranscriptWorkedSectionIdentity,
    spacingAfter: CGFloat,
    to rows: inout [TranscriptPresentationRow]
  ) {
    let reference = TranscriptWorkedItemReference(
      messageID: message.id,
      section: kind,
      itemID: itemID
    )
    rows.append(
      .init(
        id: workedItemID(
          messageID: message.id,
          section: kind,
          itemID: itemID,
          lifecycle: lifecycle
        ),
        content: workedItemContent(
          message: message,
          reference: reference,
          lifecycle: lifecycle
        ),
        estimatedHeight: estimatedHeight,
        measurementRevision: TranscriptAssistantRowProjection.measurementRevision(
          for: .assistant(message),
          waitingOnBackgroundTask: nil
        ),
        spacingAfter: spacingAfter,
        workedSection: .init(identity: identity, role: .content)
      ))
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

  private static func workedItemID(
    messageID: UUID,
    section: TranscriptWorkedSectionKind,
    itemID: String,
    lifecycle: TranscriptBlockLifecycle
  ) -> TranscriptPresentationRow.ID {
    switch lifecycle {
    case .receiving: .activeWorkedItem(messageID, section, itemID: itemID)
    case .settled: .assistantWorkedItem(messageID, section, itemID: itemID)
    }
  }

  private static func workedHeaderContent(
    message: AssistantMessage,
    kind: TranscriptWorkedSectionKind,
    lifecycle: TranscriptBlockLifecycle
  ) -> TranscriptPresentationRow.Content {
    switch lifecycle {
    case .receiving:
      .activeWorkedHeader(.init(messageID: message.id, kind: kind))
    case .settled:
      .assistantWorkedHeader(.init(message: message, kind: kind))
    }
  }

  private static func workedItemContent(
    message: AssistantMessage,
    reference: TranscriptWorkedItemReference,
    lifecycle: TranscriptBlockLifecycle
  ) -> TranscriptPresentationRow.Content {
    switch lifecycle {
    case .receiving: .activeWorkedItem(reference)
    case .settled: .assistantWorkedItem(.init(message: message, reference: reference))
    }
  }
}

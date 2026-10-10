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
    guard !items.isEmpty || deferredDetailID != nil else { return false }

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
    // Once a plan lands, the planning section settles like a finished
    // response while the work after the plan is the live one.
    let isFixedExpanded = message.turn.isWorkedSectionLive(kind)
    let defaultExpanded = isFixedExpanded
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
        estimatedHeight: 34,
        measurementRevision: TranscriptAssistantRowProjection.measurementRevision(
          for: .assistant(message),
          waitingOnBackgroundTask: nil
        ),
        spacingAfter: 12,
        workedSection: .init(
          identity: identity,
          role: .header(
            defaultExpanded: defaultExpanded,
            isFixedExpanded: isFixedExpanded
          )
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
    for item in items {
      switch item {
      case let .text(entryID, markdown):
        appendMarkdown(
          message, kind: kind, entryID: entryID, markdown: markdown,
          lifecycle: lifecycle, identity: identity, to: &rows)
      default:
        appendWorkedItemRow(
          message,
          kind: kind,
          itemID: item.id,
          estimatedHeight: estimatedHeight(for: item),
          lifecycle: lifecycle,
          identity: identity,
          to: &rows
        )
      }
    }
  }

  private static func appendMarkdown(
    _ message: AssistantMessage,
    kind: TranscriptWorkedSectionKind,
    entryID: String,
    markdown: String,
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
        precedingRole: chunk.precedingRole
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
          spacingAfter: chunkIndex == chunks.count - 1 ? 12 : 0,
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
        spacingAfter: 12,
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

  private static func estimatedHeight(for item: WorkedItem) -> CGFloat {
    switch item {
    case .text: 80
    case let .toolGroup(group): max(44, CGFloat(group.calls.count) * 34)
    case .subagents: 36
    }
  }
}

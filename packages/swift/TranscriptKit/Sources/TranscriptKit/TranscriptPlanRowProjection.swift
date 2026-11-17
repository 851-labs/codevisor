import CoreGraphics
import Foundation
import MarkdownCore

enum TranscriptPlanRowProjection {
  static func append(
    messageID: UUID,
    markdown: String,
    lifecycle: TranscriptBlockLifecycle,
    to rows: inout [TranscriptPresentationRow]
  ) {
    let blocks = TranscriptMarkdownParseCache.shared.parse(
      markdown, messageID: messageID, sourceID: "plan"
    )
    guard !blocks.isEmpty else { return }

    rows.append(
      .init(
        id: headerID(messageID: messageID, lifecycle: lifecycle),
        content: .planHeader(lifecycle: lifecycle),
        estimatedHeight: 42,
        spacingAfter: 0
      ))
    for fragment in MarkdownFragmentProjection.fragments(from: blocks) {
      let projected = TranscriptMarkdownChunk(
        messageID: messageID,
        sourceID: "plan",
        ordinal: fragment.firstOrdinal,
        content: fragment,
        documentSource: markdown,
        lifecycle: lifecycle,
        container: .planDocument,
        documentBlockCount: blocks.count
      )
      rows.append(
        .init(
          id: markdownID(
            messageID: messageID,
            ordinal: fragment.firstOrdinal,
            fragment: fragment.layout?.identity,
            lifecycle: lifecycle
          ),
          content: .markdownChunk(projected),
          estimatedHeight: projected.estimatedHeight + (projected.isLastInDocument ? 12 : 0),
          measurementRevision: projected.measurementRevision,
          spacingAfter: projected.isLastInDocument ? nil : 0
        ))
    }
  }

  private static func headerID(
    messageID: UUID,
    lifecycle: TranscriptBlockLifecycle
  ) -> TranscriptPresentationRow.ID {
    switch lifecycle {
    case .receiving: .activePlanHeader(messageID)
    case .settled: .planHeader(messageID)
    }
  }

  private static func markdownID(
    messageID: UUID,
    ordinal: Int,
    fragment: String?,
    lifecycle: TranscriptBlockLifecycle
  ) -> TranscriptPresentationRow.ID {
    switch lifecycle {
    case .receiving:
      .activePlanMarkdown(messageID, ordinal: ordinal, fragment: fragment)
    case .settled:
      .planMarkdown(messageID, ordinal: ordinal, fragment: fragment)
    }
  }
}

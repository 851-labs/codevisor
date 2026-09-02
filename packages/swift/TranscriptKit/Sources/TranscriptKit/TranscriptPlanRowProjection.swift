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
    let blocks = MarkdownParser().parse(markdown)
    guard !blocks.isEmpty else { return }

    rows.append(
      .init(
        id: headerID(messageID: messageID, lifecycle: lifecycle),
        content: .planHeader(lifecycle: lifecycle),
        estimatedHeight: 42,
        spacingAfter: 0
      ))
    for chunk in TranscriptMarkdownChunkProjection.chunks(from: blocks) {
      let projected = TranscriptMarkdownChunk(
        messageID: messageID,
        sourceID: "plan",
        ordinal: chunk.firstOrdinal,
        blocks: chunk.blocks,
        documentSource: markdown,
        lifecycle: lifecycle,
        container: .planDocument,
        documentBlockCount: blocks.count,
        fragment: chunk.fragment
      )
      rows.append(
        .init(
          id: markdownID(
            messageID: messageID,
            ordinal: chunk.firstOrdinal,
            fragment: chunk.fragment?.identity,
            lifecycle: lifecycle
          ),
          content: .markdownChunk(projected),
          estimatedHeight: estimatedHeight(
            for: chunk.blocks,
            isFirst: projected.isFirstInDocument,
            isLast: projected.isLastInDocument,
            fragment: chunk.fragment
          ),
          measurementRevision: projected.measurementRevision,
          spacingAfter: 0
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

  private static func estimatedHeight(
    for blocks: [MarkdownBlock],
    isFirst: Bool,
    isLast: Bool,
    fragment: MarkdownFragmentLayout?
  ) -> CGFloat {
    TranscriptMarkdownChunkProjection.estimatedHeight(
      for: blocks,
      fragment: fragment
    )
      + (fragment == nil && !isFirst ? 10 : 0)
      + (isLast ? 12 : 0)
  }
}

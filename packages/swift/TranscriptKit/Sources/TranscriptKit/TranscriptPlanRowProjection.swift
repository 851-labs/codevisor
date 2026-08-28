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
        for (ordinal, block) in blocks.enumerated() {
            let projected = TranscriptMarkdownBlock(
                messageID: messageID,
                sourceID: "plan",
                ordinal: ordinal,
                block: block,
                documentSource: markdown,
                lifecycle: lifecycle,
                container: .planDocument,
                blockCount: blocks.count
            )
            rows.append(
                .init(
                    id: markdownID(
                        messageID: messageID,
                        ordinal: ordinal,
                        lifecycle: lifecycle
                    ),
                    content: .markdownBlock(projected),
                    estimatedHeight: estimatedHeight(
                        for: block,
                        isFirst: ordinal == 0,
                        isLast: ordinal == blocks.count - 1
                    ),
                    measurementRevision: measurementRevision(projected),
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
        lifecycle: TranscriptBlockLifecycle
    ) -> TranscriptPresentationRow.ID {
        switch lifecycle {
        case .receiving: .activePlanMarkdown(messageID, ordinal: ordinal)
        case .settled: .planMarkdown(messageID, ordinal: ordinal)
        }
    }

    private static func estimatedHeight(
        for block: MarkdownBlock,
        isFirst: Bool,
        isLast: Bool
    ) -> CGFloat {
        let contentHeight: CGFloat =
            switch block {
            case let .heading(_, text), let .paragraph(text):
                max(24, min(360, 24 + CGFloat(text.characterCount / 72) * 20))
            case let .codeBlock(_, code, _):
                max(80, min(640, 52 + CGFloat(code.split(separator: "\n").count) * 18))
            case let .bulletList(items):
                max(28, CGFloat(items.count) * 26)
            case let .orderedList(items):
                max(28, CGFloat(items.count) * 26)
            case let .list(list):
                max(32, CGFloat(list.items.count) * 30)
            case let .blockQuote(blocks):
                max(36, CGFloat(blocks.count) * 34)
            case let .table(_, _, body):
                max(72, CGFloat(body.count + 1) * 34)
            case .thematicBreak:
                1
            }
        return contentHeight + (isFirst ? 0 : 10) + (isLast ? 12 : 0)
    }

    private static func measurementRevision(_ block: TranscriptMarkdownBlock) -> Int {
        var hasher = Hasher()
        hasher.combine(block.block.id)
        hasher.combine(block.blockCount)
        return hasher.finalize()
    }
}

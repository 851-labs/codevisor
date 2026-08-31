import Foundation
import MarkdownCore

/// A bounded group of adjacent Markdown blocks rendered by one native
/// transcript host. Text-like blocks share one TextKit surface, while blocks
/// with their own layout or interaction remain isolated in one-block chunks.
public struct TranscriptMarkdownChunk: Sendable, Equatable {
    public let messageID: UUID
    public let sourceID: String
    /// The first block's ordinal in the complete assistant response or plan.
    public let ordinal: Int
    public let blocks: [MarkdownBlock]
    public let documentSource: String
    public let lifecycle: TranscriptBlockLifecycle
    public let container: TranscriptMarkdownContainer
    /// Layout retained from a structurally complex block quote that was split
    /// into independently virtualized leaf rows. Simple quotes stay intact and
    /// leave this nil so they continue through the single TextKit fast path.
    public let fragment: TranscriptMarkdownFragment?
    /// The complete block count for a plan document, whose fragments need to
    /// know whether they draw the card's first and last edges. Assistant
    /// response chunks use zero so stable prefix rows do not change on append.
    public let documentBlockCount: Int

    public init(
        messageID: UUID,
        sourceID: String,
        ordinal: Int,
        blocks: [MarkdownBlock],
        documentSource: String,
        lifecycle: TranscriptBlockLifecycle,
        container: TranscriptMarkdownContainer,
        documentBlockCount: Int = 0,
        fragment: TranscriptMarkdownFragment? = nil
    ) {
        precondition(!blocks.isEmpty, "Markdown chunks must contain at least one block")
        self.messageID = messageID
        self.sourceID = sourceID
        self.ordinal = ordinal
        self.blocks = blocks
        self.documentSource = documentSource
        self.lifecycle = lifecycle
        self.container = container
        self.documentBlockCount = documentBlockCount
        self.fragment = fragment
    }

    public var isFirstInDocument: Bool {
        ordinal == 0 && (fragment?.isFirstInSourceBlock ?? true)
    }

    public var isLastInDocument: Bool {
        guard documentBlockCount > 0 else { return false }
        if let fragment {
            return ordinal + 1 == documentBlockCount && fragment.isLastInSourceBlock
        }
        return ordinal + blocks.count == documentBlockCount
    }
}

/// A marker painted beside one independently virtualized Markdown fragment.
/// Depth is one-based and lets a fragment retain multiple markers when nested
/// lists begin on the same leaf.
public struct TranscriptMarkdownListMarker: Sendable, Equatable, Hashable {
    public let depth: Int
    public let text: String

    public init(depth: Int, text: String) {
        self.depth = depth
        self.text = text
    }
}

public enum TranscriptMarkdownFragmentSpacing: Sendable, Equatable, Hashable {
    case none
    case block
    case listItem
}

/// Structural decoration for one leaf of a complex quote. The Markdown leaf
/// itself remains unchanged, so code blocks and tables keep their specialized
/// renderers while prose keeps the native TextKit renderer.
public struct TranscriptMarkdownFragment: Sendable, Equatable, Hashable {
    /// Stable AST path appended to the transcript row identity.
    public let identity: String
    public let quoteDepth: Int
    public let listDepth: Int
    public let listMarkers: [TranscriptMarkdownListMarker]
    public let trailingSpacing: TranscriptMarkdownFragmentSpacing
    public let isFirstInSourceBlock: Bool
    public let isLastInSourceBlock: Bool

    public init(
        identity: String,
        quoteDepth: Int,
        listDepth: Int,
        listMarkers: [TranscriptMarkdownListMarker],
        trailingSpacing: TranscriptMarkdownFragmentSpacing,
        isFirstInSourceBlock: Bool,
        isLastInSourceBlock: Bool
    ) {
        self.identity = identity
        self.quoteDepth = quoteDepth
        self.listDepth = listDepth
        self.listMarkers = listMarkers
        self.trailingSpacing = trailingSpacing
        self.isFirstInSourceBlock = isFirstInSourceBlock
        self.isLastInSourceBlock = isLastInSourceBlock
    }
}

enum TranscriptMarkdownChunkProjection {
    /// Keeps a row small enough to mount predictably while amortizing native
    /// host and TextKit setup across ordinary prose. Height is the meaningful
    /// bound: six short paragraphs are cheap, while two long wrapped paragraphs
    /// can already fill most of a viewport. The count remains a safety valve
    /// for empty or otherwise underestimated blocks.
    static let maximumEstimatedTextChunkHeight: CGFloat = 320
    static let maximumTextBlocksPerChunk = 12
    static let estimatedBlockSpacing: CGFloat = 10

    struct Chunk: Equatable {
        let firstOrdinal: Int
        let blocks: [MarkdownBlock]
        let fragment: TranscriptMarkdownFragment?

        init(
            firstOrdinal: Int,
            blocks: [MarkdownBlock],
            fragment: TranscriptMarkdownFragment? = nil
        ) {
            self.firstOrdinal = firstOrdinal
            self.blocks = blocks
            self.fragment = fragment
        }
    }

    static func chunks(from blocks: [MarkdownBlock]) -> [Chunk] {
        var chunks: [Chunk] = []
        var textBlocks: [MarkdownBlock] = []
        var textStart = 0

        func flushTextBlocks() {
            guard !textBlocks.isEmpty else { return }
            chunks.append(Chunk(firstOrdinal: textStart, blocks: textBlocks))
            textBlocks.removeAll(keepingCapacity: true)
        }

        for (ordinal, block) in blocks.enumerated() {
            if isTextBlock(block) {
                if shouldStartNewTextChunk(existing: textBlocks, appending: block) {
                    flushTextBlocks()
                }
                if textBlocks.isEmpty { textStart = ordinal }
                textBlocks.append(block)
            } else if case let .blockQuote(quotedBlocks) = block,
                requiresStructuralFragmentation(quotedBlocks)
            {
                flushTextBlocks()
                chunks.append(contentsOf: quoteFragments(from: quotedBlocks, ordinal: ordinal))
            } else {
                flushTextBlocks()
                chunks.append(Chunk(firstOrdinal: ordinal, blocks: [block]))
            }
        }
        flushTextBlocks()
        return chunks
    }

    static func estimatedHeight(for blocks: [MarkdownBlock]) -> CGFloat {
        blocks.reduce(0) { $0 + estimatedHeight(for: $1) }
            + CGFloat(max(0, blocks.count - 1)) * estimatedBlockSpacing
    }

    static func estimatedHeight(for block: MarkdownBlock) -> CGFloat {
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
    }

    private static func shouldStartNewTextChunk(
        existing: [MarkdownBlock],
        appending block: MarkdownBlock
    ) -> Bool {
        guard !existing.isEmpty else { return false }
        guard existing.count < maximumTextBlocksPerChunk else { return true }
        let nextHeight =
            estimatedHeight(for: existing)
            + estimatedBlockSpacing
            + estimatedHeight(for: block)
        return nextHeight > maximumEstimatedTextChunkHeight
    }

    private struct FragmentDraft {
        let path: String
        var blocks: [MarkdownBlock]
        let quoteDepth: Int
        let listDepth: Int
        var listMarkers: [TranscriptMarkdownListMarker]
        let listItemPath: [String]
    }

    /// Breaks only fallback quotes (those containing embedded native views)
    /// into bounded leaf rows. This removes the recursive SwiftUI layout tree
    /// from the scroll hot path without changing ordinary quote rendering.
    private static func quoteFragments(
        from blocks: [MarkdownBlock],
        ordinal: Int
    ) -> [Chunk] {
        var drafts: [FragmentDraft] = []
        append(
            blocks,
            quoteDepth: 1,
            listItemPath: [],
            path: "q",
            to: &drafts
        )
        let grouped = groupAdjacentTextDrafts(drafts)
        return grouped.enumerated().map { index, draft in
            let spacing = trailingSpacing(
                after: index,
                in: grouped
            )
            return Chunk(
                firstOrdinal: ordinal,
                blocks: draft.blocks,
                fragment: TranscriptMarkdownFragment(
                    identity: draft.path,
                    quoteDepth: draft.quoteDepth,
                    listDepth: draft.listDepth,
                    listMarkers: draft.listMarkers,
                    trailingSpacing: spacing,
                    isFirstInSourceBlock: index == 0,
                    isLastInSourceBlock: index == grouped.count - 1
                )
            )
        }
    }

    private static func append(
        _ blocks: [MarkdownBlock],
        quoteDepth: Int,
        listItemPath: [String],
        path: String,
        to drafts: inout [FragmentDraft]
    ) {
        for (index, block) in blocks.enumerated() {
            append(
                block,
                quoteDepth: quoteDepth,
                listItemPath: listItemPath,
                path: "\(path).b\(index)",
                to: &drafts
            )
        }
    }

    private static func append(
        _ block: MarkdownBlock,
        quoteDepth: Int,
        listItemPath: [String],
        path: String,
        to drafts: inout [FragmentDraft]
    ) {
        switch block {
        case let .blockQuote(blocks) where requiresStructuralFragmentation(blocks):
            append(
                blocks,
                quoteDepth: quoteDepth + 1,
                listItemPath: listItemPath,
                path: "\(path).q",
                to: &drafts
            )

        case let .list(list) where requiresStructuralFragmentation(list.items.flatMap(\.blocks)):
            append(
                list,
                quoteDepth: quoteDepth,
                listItemPath: listItemPath,
                path: "\(path).l",
                to: &drafts
            )

        default:
            drafts.append(
                FragmentDraft(
                    path: path,
                    blocks: [block],
                    quoteDepth: quoteDepth,
                    listDepth: listItemPath.count,
                    listMarkers: [],
                    listItemPath: listItemPath
                )
            )
        }
    }

    private static func append(
        _ list: MarkdownList,
        quoteDepth: Int,
        listItemPath: [String],
        path: String,
        to drafts: inout [FragmentDraft]
    ) {
        for (index, item) in list.items.enumerated() {
            let itemComponent = "\(path).i\(index)"
            let nestedItemPath = listItemPath + [itemComponent]
            let firstDraft = drafts.count
            append(
                item.blocks,
                quoteDepth: quoteDepth,
                listItemPath: nestedItemPath,
                path: itemComponent,
                to: &drafts
            )
            if firstDraft == drafts.count {
                drafts.append(
                    FragmentDraft(
                        path: "\(itemComponent).empty",
                        blocks: [.paragraph(MarkdownText(""))],
                        quoteDepth: quoteDepth,
                        listDepth: nestedItemPath.count,
                        listMarkers: [],
                        listItemPath: nestedItemPath
                    )
                )
            }
            drafts[firstDraft].listMarkers.append(
                TranscriptMarkdownListMarker(
                    depth: nestedItemPath.count,
                    text: marker(for: list, item: item, at: index)
                )
            )
            drafts[firstDraft].listMarkers.sort { $0.depth < $1.depth }
        }
    }

    private static func marker(
        for list: MarkdownList,
        item: MarkdownListItem,
        at index: Int
    ) -> String {
        if item.isTask { return item.isChecked ? "☑" : "☐" }
        return list.isOrdered ? "\(list.start + index)\(list.delimiter)" : "•"
    }

    private static func groupAdjacentTextDrafts(
        _ drafts: [FragmentDraft]
    ) -> [FragmentDraft] {
        var result: [FragmentDraft] = []
        for draft in drafts {
            if var previous = result.last,
                previous.blocks.count + draft.blocks.count <= maximumTextBlocksPerChunk,
                estimatedHeight(for: previous.blocks + draft.blocks)
                    <= maximumEstimatedTextChunkHeight,
                previous.blocks.allSatisfy(isTextBlock),
                draft.blocks.allSatisfy(isTextBlock),
                draft.listMarkers.isEmpty,
                previous.quoteDepth == draft.quoteDepth,
                previous.listDepth == draft.listDepth,
                previous.listItemPath == draft.listItemPath
            {
                previous.blocks.append(contentsOf: draft.blocks)
                result[result.count - 1] = previous
            } else {
                result.append(draft)
            }
        }
        return result
    }

    private static func trailingSpacing(
        after index: Int,
        in drafts: [FragmentDraft]
    ) -> TranscriptMarkdownFragmentSpacing {
        guard drafts.indices.contains(index + 1) else { return .none }
        let current = drafts[index].listItemPath
        let next = drafts[index + 1].listItemPath
        if !current.isEmpty,
            current.count == next.count,
            current.dropLast().elementsEqual(next.dropLast()),
            current.last != next.last
        {
            return .listItem
        }
        return .block
    }

    private static func requiresStructuralFragmentation(_ blocks: [MarkdownBlock]) -> Bool {
        blocks.contains(where: requiresStructuralFragmentation)
    }

    private static func requiresStructuralFragmentation(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .codeBlock, .table, .thematicBreak:
            true
        case let .list(list):
            requiresStructuralFragmentation(list.items.flatMap(\.blocks))
        case let .blockQuote(blocks):
            requiresStructuralFragmentation(blocks)
        case .heading, .paragraph, .bulletList, .orderedList:
            false
        }
    }

    private static func isTextBlock(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList:
            true
        case .codeBlock, .list, .blockQuote, .table, .thematicBreak:
            false
        }
    }
}

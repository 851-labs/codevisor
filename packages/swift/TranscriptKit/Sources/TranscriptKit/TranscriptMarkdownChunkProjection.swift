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
  public let fragment: MarkdownFragmentLayout?
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
    fragment: MarkdownFragmentLayout? = nil
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

  var estimatedHeight: CGFloat {
    TranscriptMarkdownChunkProjection.estimatedHeight(
      for: blocks,
      fragment: fragment
    )
  }

  var measurementRevision: Int {
    var hasher = Hasher()
    for block in blocks {
      hasher.combine(block.id)
    }
    hasher.combine(documentBlockCount)
    hasher.combine(fragment)
    return hasher.finalize()
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
    let fragment: MarkdownFragmentLayout?

    init(
      firstOrdinal: Int,
      blocks: [MarkdownBlock],
      fragment: MarkdownFragmentLayout? = nil
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
        chunks.append(
          contentsOf: structuralFragments(
            from: quotedBlocks,
            ordinal: ordinal,
            quoteDepth: 1,
            path: "q"
          )
        )
      } else if case let .list(list) = block,
        requiresStructuralFragmentation(list.items.flatMap(\.blocks))
      {
        flushTextBlocks()
        chunks.append(
          contentsOf: structuralFragments(
            from: [block],
            ordinal: ordinal,
            quoteDepth: 0,
            path: "l"
          )
        )
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

  static func estimatedHeight(
    for blocks: [MarkdownBlock],
    fragment: MarkdownFragmentLayout?
  ) -> CGFloat {
    let content = estimatedHeight(for: blocks)
    guard let fragment else { return content }
    switch fragment.trailingSpacing {
    case .none: return content
    case .block: return content + 10
    case .listItem: return content + 4
    }
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
    var listMarkers: [MarkdownFragmentLayout.ListMarker]
    let listItemPath: [String]
  }

  /// Breaks structural containers containing code, tables, or rules into
  /// bounded leaf rows. This removes the recursive SwiftUI layout tree from
  /// the scroll hot path without changing ordinary prose-only containers.
  private static func structuralFragments(
    from blocks: [MarkdownBlock],
    ordinal: Int,
    quoteDepth: Int,
    path: String
  ) -> [Chunk] {
    var drafts: [FragmentDraft] = []
    append(
      blocks,
      quoteDepth: quoteDepth,
      listItemPath: [],
      path: path,
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
        fragment: MarkdownFragmentLayout(
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
        MarkdownFragmentLayout.ListMarker(
          depth: nestedItemPath.count,
          text: list.marker(for: item, at: index)
        )
      )
      drafts[firstDraft].listMarkers.sort { $0.depth < $1.depth }
    }
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
  ) -> MarkdownFragmentLayout.TrailingSpacing {
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

  /// Blocks that share one prose row. A list or quote that carries no code,
  /// table, or rule renders inline with surrounding prose, so it must stay
  /// in the prose chunk: giving it a row of its own — and merging it back
  /// when the parser reshapes it a token later — changes row identity and
  /// restarts the reveal animation for everything in the moved block.
  private static func isTextBlock(_ block: MarkdownBlock) -> Bool {
    switch block {
    case .heading, .paragraph, .bulletList, .orderedList:
      true
    case let .list(list):
      !requiresStructuralFragmentation(list.items.flatMap(\.blocks))
    case let .blockQuote(blocks):
      !requiresStructuralFragmentation(blocks)
    case .codeBlock, .table, .thematicBreak:
      false
    }
  }
}

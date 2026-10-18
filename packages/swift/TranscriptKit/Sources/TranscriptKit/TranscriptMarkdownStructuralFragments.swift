import Foundation
import MarkdownCore

enum TranscriptMarkdownStructuralFragments {
  private struct FragmentDraft {
    let path: String
    var blocks: [MarkdownBlock]
    let quoteDepth: Int
    let listDepth: Int
    var listMarkers: [MarkdownFragmentLayout.ListMarker]
    let listItemPath: [String]

    func canGroupText(with next: Self) -> Bool {
      guard blocks.count + next.blocks.count <= TranscriptMarkdownChunkProjection.maximumTextBlocksPerChunk,
        TranscriptMarkdownChunkProjection.estimatedHeight(for: blocks + next.blocks)
          <= TranscriptMarkdownChunkProjection.maximumEstimatedTextChunkHeight,
        blocks.allSatisfy(TranscriptMarkdownStructuralFragments.isTextBlock),
        next.blocks.allSatisfy(TranscriptMarkdownStructuralFragments.isTextBlock),
        next.listMarkers.isEmpty,
        quoteDepth == next.quoteDepth,
        listDepth == next.listDepth,
        listItemPath == next.listItemPath
      else { return false }
      return true
    }
  }

  static func chunks(
    from blocks: [MarkdownBlock],
    ordinal: Int,
    quoteDepth: Int,
    path: String
  ) -> [TranscriptMarkdownChunkProjection.Chunk] {
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
      return TranscriptMarkdownChunkProjection.Chunk(
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
    case let .blockQuote(blocks) where requiresFragmentation(blocks):
      append(
        blocks,
        quoteDepth: quoteDepth + 1,
        listItemPath: listItemPath,
        path: "\(path).q",
        to: &drafts
      )

    case let .list(list) where requiresFragmentation(list.items.flatMap(\.blocks)):
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
          text: list.marker(for: item, at: index, depth: nestedItemPath.count - 1)
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
        previous.canGroupText(with: draft)
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
    let current = drafts[index]
    let next = drafts[index + 1]
    if !current.listItemPath.isEmpty, !next.listItemPath.isEmpty {
      return .listItem
    }
    return .block(after: current.blocks[current.blocks.count - 1].role, before: next.blocks[0].role)
  }

  static func requiresFragmentation(_ blocks: [MarkdownBlock]) -> Bool {
    blocks.contains(where: requiresFragmentation)
  }

  private static func requiresFragmentation(_ block: MarkdownBlock) -> Bool {
    switch block {
    case .codeBlock, .table, .thematicBreak:
      true
    case let .list(list):
      requiresFragmentation(list.items.flatMap(\.blocks))
    case let .blockQuote(blocks):
      requiresFragmentation(blocks)
    case .heading, .paragraph, .bulletList, .orderedList:
      false
    }
  }

  static func isTextBlock(_ block: MarkdownBlock) -> Bool {
    switch block {
    case .heading, .paragraph, .bulletList, .orderedList:
      true
    case let .list(list):
      !requiresFragmentation(list.items.flatMap(\.blocks))
    case let .blockQuote(blocks):
      !requiresFragmentation(blocks)
    case .codeBlock, .table, .thematicBreak:
      false
    }
  }
}

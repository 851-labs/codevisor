enum MarkdownStructuralFragments {
  private struct Draft {
    let path: String
    var blocks: [MarkdownBlock]
    let quoteListDepths: [Int]
    let listDepth: Int
    var listMarkers: [MarkdownFragmentLayout.ListMarker]
    let listItemPath: [String]

    var isText: Bool { blocks.allSatisfy(MarkdownFragmentProjection.isTextBlock) }

    func canGroupText(with next: Self) -> Bool {
      isText && next.isText && next.listMarkers.isEmpty && sharesPlacement(with: next)
        && MarkdownFragmentProjection.fitsInTextFragment(blocks + next.blocks)
    }

    private func sharesPlacement(with next: Self) -> Bool {
      quoteListDepths == next.quoteListDepths && listDepth == next.listDepth && listItemPath == next.listItemPath
    }
  }

  static func fragments(
    from blocks: [MarkdownBlock],
    ordinal: Int,
    quoteListDepths: [Int],
    path: String
  ) -> [MarkdownFragment] {
    var drafts: [Draft] = []
    append(blocks, quoteListDepths: quoteListDepths, listItemPath: [], path: path, to: &drafts)
    let grouped = groupAdjacentText(drafts)
    return grouped.enumerated().map { index, draft in
      MarkdownFragment(
        blocks: draft.blocks,
        layout: MarkdownFragmentLayout(
          identity: draft.path,
          quoteListDepths: draft.quoteListDepths,
          listDepth: draft.listDepth,
          listMarkers: draft.listMarkers,
          trailingSpacing: trailingSpacing(after: index, in: grouped),
          isFirstInSourceBlock: index == 0,
          isLastInSourceBlock: index == grouped.count - 1
        ),
        firstOrdinal: ordinal
      )
    }
  }

  private static func append(
    _ blocks: [MarkdownBlock],
    quoteListDepths: [Int],
    listItemPath: [String],
    path: String,
    to drafts: inout [Draft]
  ) {
    for (index, block) in blocks.enumerated() {
      append(
        block, quoteListDepths: quoteListDepths, listItemPath: listItemPath, path: "\(path).b\(index)", to: &drafts)
    }
  }

  private static func append(
    _ block: MarkdownBlock,
    quoteListDepths: [Int],
    listItemPath: [String],
    path: String,
    to drafts: inout [Draft]
  ) {
    switch block {
    case let .blockQuote(blocks) where !MarkdownFragmentProjection.rendersInPlace(block):
      append(
        blocks, quoteListDepths: quoteListDepths + [listItemPath.count], listItemPath: listItemPath,
        path: "\(path).q", to: &drafts)

    case let .list(list) where !MarkdownFragmentProjection.rendersInPlace(block):
      append(list, quoteListDepths: quoteListDepths, listItemPath: listItemPath, path: "\(path).l", to: &drafts)

    default:
      drafts.append(
        Draft(
          path: path,
          blocks: [block],
          quoteListDepths: quoteListDepths,
          listDepth: listItemPath.count,
          listMarkers: [],
          listItemPath: listItemPath
        )
      )
    }
  }

  private static func append(
    _ list: MarkdownList,
    quoteListDepths: [Int],
    listItemPath: [String],
    path: String,
    to drafts: inout [Draft]
  ) {
    for (index, item) in list.items.enumerated() {
      let itemComponent = "\(path).i\(index)"
      let nestedItemPath = listItemPath + [itemComponent]
      let firstDraft = drafts.count
      append(
        item.blocks, quoteListDepths: quoteListDepths, listItemPath: nestedItemPath, path: itemComponent, to: &drafts)
      if firstDraft == drafts.count {
        drafts.append(
          Draft(
            path: "\(itemComponent).empty",
            blocks: [.paragraph(MarkdownText(""))],
            quoteListDepths: quoteListDepths,
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

  private static func groupAdjacentText(_ drafts: [Draft]) -> [Draft] {
    var result: [Draft] = []
    for draft in drafts {
      if var previous = result.last, previous.canGroupText(with: draft) {
        previous.blocks.append(contentsOf: draft.blocks)
        result[result.count - 1] = previous
      } else {
        result.append(draft)
      }
    }
    return result
  }

  private static func trailingSpacing(after index: Int, in drafts: [Draft]) -> MarkdownFragmentLayout.TrailingSpacing {
    guard drafts.indices.contains(index + 1) else { return .none }

    let current = drafts[index]
    let next = drafts[index + 1]
    if !current.listItemPath.isEmpty, !next.listItemPath.isEmpty {
      return .listItem
    }
    return .block(after: current.blocks[current.blocks.count - 1].role, before: next.blocks[0].role)
  }
}

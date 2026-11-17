public struct MarkdownFragment: Sendable, Equatable, Hashable {
  public let blocks: [MarkdownBlock]
  public let layout: MarkdownFragmentLayout?
  public let firstOrdinal: Int
  public internal(set) var precedingRole: MarkdownBlockRole?

  init(blocks: [MarkdownBlock], layout: MarkdownFragmentLayout? = nil, firstOrdinal: Int = 0) {
    precondition(!blocks.isEmpty, "Markdown fragments must contain at least one block")
    precondition(
      blocks.allSatisfy(MarkdownFragmentProjection.rendersInPlace),
      "Markdown fragments must not nest blocks that need their own fragment"
    )
    self.blocks = blocks
    self.layout = layout
    self.firstOrdinal = firstOrdinal
  }

  var startsSourceBlock: Bool { layout?.isFirstInSourceBlock ?? true }
}

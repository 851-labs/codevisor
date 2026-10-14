public struct MarkdownFragmentLayout: Sendable, Equatable, Hashable {
  public struct ListMarker: Sendable, Equatable, Hashable, Identifiable {
    public let depth: Int
    public let text: String

    public var id: Int { depth }

    public init(depth: Int, text: String) {
      self.depth = depth
      self.text = text
    }
  }

  public enum TrailingSpacing: Sendable, Equatable, Hashable {
    case none
    case block(after: MarkdownBlockRole, before: MarkdownBlockRole)
    case listItem
  }

  public let identity: String
  public let quoteDepth: Int
  public let listDepth: Int
  public let listMarkers: [ListMarker]
  public let trailingSpacing: TrailingSpacing
  public let isFirstInSourceBlock: Bool
  public let isLastInSourceBlock: Bool

  public init(
    identity: String = "",
    quoteDepth: Int,
    listDepth: Int,
    listMarkers: [ListMarker],
    trailingSpacing: TrailingSpacing,
    isFirstInSourceBlock: Bool = true,
    isLastInSourceBlock: Bool = true
  ) {
    self.identity = identity
    self.quoteDepth = max(0, quoteDepth)
    self.listDepth = max(0, listDepth)
    self.listMarkers = listMarkers
    self.trailingSpacing = trailingSpacing
    self.isFirstInSourceBlock = isFirstInSourceBlock
    self.isLastInSourceBlock = isLastInSourceBlock
  }
}

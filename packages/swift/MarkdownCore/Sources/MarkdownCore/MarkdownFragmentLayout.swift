/// Structural context for a leaf extracted from a complex Markdown container.
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
    case block
    case listItem
  }

  /// Stable AST path used as part of a transcript row identity.
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

public extension MarkdownList {
  /// Disc, circle, then square: nested bullet lists stay distinguishable
  /// from their parent the way browsers vary unordered markers by depth.
  static func bullet(depth: Int) -> String {
    switch depth {
    case 0: "•"
    case 1: "◦"
    default: "▪"
    }
  }

  /// Bullets are drawn bold; at body size the regular glyphs are too small
  /// to tell a nested circle from a disc.
  static func isBullet(_ marker: String) -> Bool {
    marker == "•" || marker == "◦" || marker == "▪"
  }

  /// `depth` counts the lists enclosing this one; it only affects bullets.
  func marker(for item: MarkdownListItem, at index: Int, depth: Int = 0) -> String {
    if item.isTask { return item.isChecked ? "☑" : "☐" }
    return isOrdered ? "\(start + index)\(delimiter)" : Self.bullet(depth: depth)
  }
}

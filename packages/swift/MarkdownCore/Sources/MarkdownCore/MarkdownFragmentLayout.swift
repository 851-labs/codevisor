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

  /// One nesting level of a fragmented list, outermost first. `widestMarker`
  /// is the widest marker in that whole list, so every row of every item —
  /// including a code block that draws no marker, and item "1." beside item
  /// "10000." — shares one column. Renderers measure the string; keeping it
  /// here lets the column follow Dynamic Type instead of a width captured
  /// when the row was projected.
  public struct ListLevel: Sendable, Equatable, Hashable {
    public let widestMarker: String

    public init(widestMarker: String) {
      self.widestMarker = widestMarker
    }
  }

  public enum TrailingSpacing: Sendable, Equatable, Hashable {
    case none
    /// Resolved through `MarkdownSpacing.gap(after:before:)`.
    case block(after: MarkdownBlockRole, before: MarkdownBlockRole)
    case listItem
  }

  /// Stable AST path used as part of a transcript row identity.
  public let identity: String
  public let quoteDepth: Int
  public let listDepth: Int
  public let listMarkers: [ListMarker]
  /// Marker columns from the outermost list in. Empty only for rows that
  /// are not inside a list; a fragmented list row has one entry per depth.
  public let listLevels: [ListLevel]
  public let trailingSpacing: TrailingSpacing
  public let isFirstInSourceBlock: Bool
  public let isLastInSourceBlock: Bool

  public init(
    identity: String = "",
    quoteDepth: Int,
    listDepth: Int,
    listMarkers: [ListMarker],
    listLevels: [ListLevel] = [],
    trailingSpacing: TrailingSpacing,
    isFirstInSourceBlock: Bool = true,
    isLastInSourceBlock: Bool = true
  ) {
    self.identity = identity
    self.quoteDepth = max(0, quoteDepth)
    self.listDepth = max(0, listDepth)
    self.listMarkers = listMarkers
    self.listLevels = listLevels
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

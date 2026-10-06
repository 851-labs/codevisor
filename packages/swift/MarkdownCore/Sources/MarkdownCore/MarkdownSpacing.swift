import CoreGraphics

/// What a block is for vertical rhythm: the only property spacing depends on.
/// Small enough to travel with transcript rows, which need the role of the
/// block above them without holding that block.
public enum MarkdownBlockRole: Sendable, Equatable, Hashable {
  case paragraph
  case heading(level: Int)
  case list
  case codeBlock
  case table
  case blockQuote
  case thematicBreak
}

public extension MarkdownBlock {
  var role: MarkdownBlockRole {
    switch self {
    case let .heading(level, _): .heading(level: level)
    case .paragraph: .paragraph
    case .bulletList, .orderedList, .list: .list
    case .codeBlock: .codeBlock
    case .table: .table
    case .blockQuote: .blockQuote
    case .thematicBreak: .thematicBreak
    }
  }
}

/// Vertical rhythm for rendered Markdown, in multiples of the body font size
/// so it scales with Dynamic Type. Every renderer — TextKit runs, native and
/// SwiftUI block stacks, and transcript rows split from one document — asks
/// this one value for the space between two blocks.
public struct MarkdownSpacing: Sendable, Equatable, Hashable {
  /// Line height of body text; long reading passages want loose leading.
  /// The leading it implies is shared by every line, headings included:
  /// TextKit 1 adds line spacing below a line and TextKit 2 above it, so
  /// streaming and settled text only measure alike when it never varies.
  public var lineHeight: CGFloat = 1.55
  /// Between paragraphs, code blocks, tables, quotes, and lists.
  public var paragraph: CGFloat = 1
  /// Above H1–H3: a new section starts here.
  public var majorHeading: CGFloat = 1.5
  /// Above H4–H6.
  public var minorHeading: CGFloat = 1
  /// Below any heading, so it reads as part of the content it introduces.
  public var belowHeading: CGFloat = 0.15
  /// Between list items, and between the blocks inside one item.
  public var listItem: CGFloat = 0.25

  public init() {}

  /// Space between `previous` and `next`, beyond the line's own leading.
  /// Nothing goes above the first block: its container owns that edge.
  public func gap(after previous: MarkdownBlockRole?, before next: MarkdownBlockRole) -> CGFloat {
    guard let previous else { return 0 }
    if case let .heading(level) = next {
      return level <= 3 ? majorHeading : minorHeading
    }
    if case .heading = previous { return belowHeading }
    return paragraph
  }
}

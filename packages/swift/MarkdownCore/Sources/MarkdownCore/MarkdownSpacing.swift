import CoreGraphics

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

public struct MarkdownSpacing: Sendable, Equatable, Hashable {
  public var lineHeight: CGFloat = 1.55
  public var paragraph: CGFloat = 1
  public var majorHeading: CGFloat = 1.5
  public var minorHeading: CGFloat = 1
  public var belowHeading: CGFloat = 0.15
  public var aboveList: CGFloat = 0.5
  public var listItem: CGFloat = 0.25

  public init() {}

  public func gap(after previous: MarkdownBlockRole?, before next: MarkdownBlockRole) -> CGFloat {
    guard let previous else { return 0 }
    if case let .heading(level) = next {
      return level <= 3 ? majorHeading : minorHeading
    }
    if case .heading = previous { return belowHeading }
    if previous == .paragraph, next == .list { return aboveList }
    return paragraph
  }
}

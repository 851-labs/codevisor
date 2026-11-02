import Foundation
import MarkdownCore

public enum TranscriptBotPartStyle: Sendable, Equatable {
  case text
  case code
  case table
  case quote
  case callout
  case image(source: String, alt: String)

  public init(blocks: [MarkdownBlock]) {
    guard blocks.count == 1 else {
      self = .text
      return
    }
    self = Self.style(of: blocks[0])
  }

  public var standsAlone: Bool { self != .text }

  private static func style(of block: MarkdownBlock) -> Self {
    switch block {
    case .codeBlock: .code
    case .table: .table
    case .blockQuote: .quote
    case let .paragraph(text): image(in: text) ?? .text
    default: .text
    }
  }

  private static func image(in text: MarkdownText) -> Self? {
    let content = text.spans.filter { !isBlank($0) }
    guard content.count == 1, case let .image(alt, source, _) = content[0] else { return nil }
    return .image(source: source, alt: MarkdownText(spans: alt).plainText)
  }

  static func isBlank(_ span: MarkdownSpan) -> Bool {
    switch span {
    case let .text(text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .softBreak, .hardBreak: true
    default: false
    }
  }
}

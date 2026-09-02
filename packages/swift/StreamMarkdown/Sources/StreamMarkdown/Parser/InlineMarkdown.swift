import Foundation
import SwiftUI

/// Converts MD4C's resolved semantic spans to `AttributedString`.
public enum InlineMarkdown {
  /// Compatibility entry point for standalone inline fragments. Production
  /// block rendering uses the semantic overload so document-level reference
  /// links are not reparsed out of context.
  public static func attributedString(from markdown: String) -> AttributedString {
    attributedString(from: MarkdownParser().parseInline(markdown))
  }

  public static func attributedString(from text: MarkdownText) -> AttributedString {
    render(text.spans, intent: [])
  }

  public static func attributedString(from markdown: String, theme: MarkdownTheme) -> AttributedString {
    attributedString(from: MarkdownParser().parseInline(markdown), theme: theme)
  }

  public static func attributedString(from text: MarkdownText, theme: MarkdownTheme) -> AttributedString {
    styleInlineCode(in: attributedString(from: text), theme: theme)
  }

  private static func render(
    _ spans: [MarkdownSpan],
    intent: InlinePresentationIntent
  ) -> AttributedString {
    var result = AttributedString()
    for span in spans {
      switch span {
      case let .text(text):
        result += attributed(text, intent: intent)
      case let .emphasis(children):
        result += render(children, intent: intent.union(.emphasized))
      case let .strong(children):
        result += render(children, intent: intent.union(.stronglyEmphasized))
      case let .strikethrough(children):
        result += render(children, intent: intent.union(.strikethrough))
      case let .code(code):
        result += attributed(code, intent: intent.union(.code))
      case let .link(children, destination, _):
        var linked = render(children, intent: intent)
        if let url = safeURL(destination) { linked.link = url }
        result += linked
      case let .image(alt, source, _):
        var renderedAlt = render(alt, intent: intent)
        if let url = safeURL(source) { renderedAlt.link = url }
        result += renderedAlt
      case .softBreak:
        result += attributed("\n", intent: intent.union(.softBreak))
      case .hardBreak:
        result += attributed("\n", intent: intent.union(.lineBreak))
      }
    }
    return result
  }

  private static func attributed(
    _ text: String,
    intent: InlinePresentationIntent
  ) -> AttributedString {
    var result = AttributedString(text)
    if !intent.isEmpty { result.inlinePresentationIntent = intent }
    return result
  }

  /// Keep local project paths and the schemes Codevisor can safely hand to
  /// the system. Raw `javascript:`/`data:` links remain visible text but are
  /// deliberately not interactive.
  private static func safeURL(_ destination: String) -> URL? {
    guard !destination.isEmpty, let url = URL(string: destination) else { return nil }
    guard let scheme = url.scheme?.lowercased() else { return url }
    switch scheme {
    case "http", "https", "mailto", "tel", "file": return url
    default: return nil
    }
  }

  /// Styles inline code as rounded TextKit chips.
  public static func styleInlineCode(in attributed: AttributedString, theme: MarkdownTheme) -> AttributedString {
    guard attributed.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true })
    else { return attributed }

    var result = AttributedString()
    for run in attributed.runs {
      var piece = AttributedString(attributed[run.range])
      guard run.inlinePresentationIntent?.contains(.code) == true else {
        result += piece
        continue
      }
      piece.font = theme.inlineCodeFont
      piece[InlineCodeChipAttribute.self] = true
      var pad = AttributedString("\u{202F}")
      pad.font = theme.inlineCodeFont
      pad[InlineCodeChipAttribute.self] = true
      result += pad + piece + pad
    }
    return result
  }

  static func chipPieces(in attributed: AttributedString) -> [(text: AttributedString, isChip: Bool)] {
    var pieces: [(text: AttributedString, isChip: Bool)] = []
    for run in attributed.runs {
      let isChip = run[InlineCodeChipAttribute.self] == true
      let piece = AttributedString(attributed[run.range])
      if !pieces.isEmpty, pieces[pieces.count - 1].isChip == isChip {
        pieces[pieces.count - 1].text += piece
      } else {
        pieces.append((piece, isChip))
      }
    }
    return pieces
  }
}

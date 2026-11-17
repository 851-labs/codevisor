import StreamMarkdown
import SwiftUI
import TranscriptKit

#if canImport(UIKit)
  import UIKit

  private typealias MessageFont = UIFont
#else
  import AppKit

  private typealias MessageFont = NSFont
#endif

@MainActor
public enum TranscriptBotMessageWidth {
  private struct Key: Hashable {
    let markdown: String
    let pointSize: CGFloat
    let theme: Int
  }

  private static var cache: [Key: CGFloat] = [:]
  private static let cacheLimit = 1_024

  public static func natural(of content: TranscriptBotMessageContent, theme: MarkdownTheme) -> CGFloat {
    let body = BodyTextMetrics.font
    let key = Key(markdown: content.markdown, pointSize: body.pointSize, theme: theme.renderFingerprint)
    if let cached = cache[key] { return cached }
    if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
    let width = max(
      measure(content.markdown, body: body), MarkdownTableNaturalWidth.widest(in: content.fragments, theme: theme),
      nestedCodeWidth(in: content.fragments))
    cache[key] = width
    return width
  }

  public static func width(
    of content: TranscriptBotMessageContent, theme: MarkdownTheme, fitting available: CGFloat
  ) -> CGFloat {
    min(natural(of: content, theme: theme), available)
  }

  private static var codeFont: MessageFont {
    MessageFont.monospacedSystemFont(
      ofSize: MessageFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
  }

  private static func measure(_ markdown: String, body: MessageFont) -> CGFloat {
    let code = codeFont
    var inFence = false
    var widest: CGFloat = 0
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        inFence.toggle()
        continue
      }
      let width = inFence ? codeWidth(of: line, font: code) : textWidth(of: line, font: body)
      widest = max(widest, ceil(width))
    }
    return max(widest, 1)
  }

  private static func nestedCodeWidth(in fragments: [MarkdownFragment]) -> CGFloat {
    let font = codeFont
    return fragments.reduce(0) { widest, fragment in
      guard let layout = fragment.layout else { return widest }
      let indent = MarkdownFragmentMetrics.contentIndent(of: layout)
      return fragment.blocks.reduce(widest) { result, block in
        guard case let .codeBlock(_, code, _) = block else { return result }
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        return max(result, ceil(indent + (lines.map { codeWidth(of: $0, font: font) }.max() ?? 0)))
      }
    }
  }

  private static func codeWidth(of line: Substring, font: MessageFont) -> CGFloat {
    (String(line) as NSString).size(withAttributes: [.font: font]).width + 24
  }

  private static func linkTextOnly(_ line: String) -> String {
    line.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
  }

  private static func textWidth(of line: Substring, font: MessageFont) -> CGFloat {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let quoteDepth = trimmed.prefix { $0 == ">" || $0 == " " }.filter { $0 == ">" }.count
    let shown = linkTextOnly(quoteDepth > 0 ? String(trimmed.drop { $0 == ">" || $0 == " " }) : String(line))
    let isListItem = shown.range(of: #"^\s*([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil
    let indent = (isListItem ? 24 : 0) + CGFloat(quoteDepth) * MarkdownFragmentMetrics.quoteIndent
    let codeSpans = CGFloat(line.filter { $0 == "`" }.count / 2)
    return (shown as NSString).size(withAttributes: [.font: font]).width + indent + codeSpans * 14 + 4
  }
}

extension View {
  public func transcriptBotMessageWidth(fitting content: TranscriptBotMessageContent) -> some View {
    modifier(TranscriptBotMessageWidthModifier(content: content))
  }
}

private struct TranscriptBotMessageWidthModifier: ViewModifier {
  let content: TranscriptBotMessageContent
  @Environment(\.markdownTheme) private var theme
  @Environment(\.streamMarkdownTextLayoutWidth) private var available

  func body(content view: Content) -> some View {
    let width = bubbleContentWidth
    view
      .environment(\.streamMarkdownTextLayoutWidth, width)
      .environment(\.markdownTableBleedLimit, 0)
      .frame(maxWidth: width ?? TranscriptBotMessageWidth.natural(of: content, theme: theme), alignment: .leading)
  }

  private var bubbleContentWidth: CGFloat? {
    available.map { TranscriptBotMessageWidth.width(of: content, theme: theme, fitting: $0) }
  }
}

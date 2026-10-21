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
    let body = MessageFont.preferredFont(forTextStyle: .body)
    let key = Key(markdown: content.markdown, pointSize: body.pointSize, theme: theme.renderFingerprint)
    if let cached = cache[key] { return cached }
    if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
    let width = max(
      measure(content.markdown, body: body), MarkdownTableNaturalWidth.widest(in: content.blocks, theme: theme))
    cache[key] = width
    return width
  }

  private static func measure(_ markdown: String, body: MessageFont) -> CGFloat {
    let code = MessageFont.monospacedSystemFont(ofSize: body.pointSize * 0.9, weight: .regular)
    var inFence = false
    var widest: CGFloat = 0
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        inFence.toggle()
        continue
      }
      let font = inFence ? code : body
      let indent: CGFloat =
        !inFence && trimmed.range(of: #"^([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil ? 24 : 0
      let width = (String(line) as NSString).size(withAttributes: [.font: font]).width
      let codeSpans = inFence ? 0 : CGFloat(line.filter { $0 == "`" }.count / 2)
      widest = max(widest, ceil(width + indent + codeSpans * 14 + (inFence ? 24 : 4)))
    }
    return max(widest, 1)
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

  func body(content view: Content) -> some View {
    let natural = TranscriptBotMessageWidth.natural(of: content, theme: theme)
    view
      .transformEnvironment(\.streamMarkdownTextLayoutWidth) { width in
        width = width.map { min($0, natural) }
      }
      .environment(\.markdownTableBleedLimit, 0)
      .frame(maxWidth: natural, alignment: .leading)
  }
}

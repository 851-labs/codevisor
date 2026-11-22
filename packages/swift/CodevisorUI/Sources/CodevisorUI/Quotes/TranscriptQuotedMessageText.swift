import StreamMarkdown
import SwiftUI
import TranscriptKit

public struct TranscriptQuotedMessageText: View {
  @Environment(\.transcriptQuoteActions) private var actions
  let prompt: TranscriptQuotedPrompt
  let font: OSFont
  let color: Color

  public init(_ prompt: TranscriptQuotedPrompt, font: OSFont, color: Color) {
    self.prompt = prompt
    self.font = font
    self.color = color
  }

  public var body: some View {
    SelectableTextView(attributedText: attributedText, fillsWidth: false)
      .accessibilityLabel(prompt.readableText)
      .environment(\.textCopyAction, Self.copyAction)
      .transformEnvironment(\.markdownLinkAction) { [actions, quotes = prompt.quotes] action in
        action = Self.revealingQuotes(quotes, actions: actions, otherwise: action)
      }
  }

  private var attributedText: NSAttributedString {
    TranscriptQuotedMessageTextCache.shared.text(for: prompt, font: font, color: color)
  }

  private static var copyAction: TextCopyAction {
    TextCopyAction { copied in
      let prompt = TranscriptQuoteBadgeText.prompt(in: copied)
      guard !prompt.quotes.isEmpty else { return false }

      TranscriptQuotePasteboard.copy(prompt)
      return true
    }
  }

  private static func revealingQuotes(
    _ quotes: [TranscriptQuote], actions: TranscriptQuoteActions?, otherwise fallback: MarkdownLinkAction?
  ) -> MarkdownLinkAction {
    MarkdownLinkAction(
      { url in
        guard let index = TranscriptQuoteLink.quoteIndex(of: url) else { return fallback?(url) ?? false }
        if quotes.indices.contains(index) { actions?.reveal(quotes[index]) }
        return true
      },
      images: fallback?.images,
      webLinks: fallback?.webLinks
    )
  }
}

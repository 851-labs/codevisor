import AppKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

enum TranscriptSelectionSource {
  case mounted([any TranscriptTextSurface])
  case cached([NSAttributedString])
  case projected([TranscriptQuotedPrompt])

  var surfaceLengths: [Int] {
    switch self {
    case let .mounted(surfaces): surfaces.map(\.transcriptTextLength)
    case let .cached(texts): texts.map(\.length)
    case let .projected(prompts): prompts.map { ($0.text as NSString).length }
    }
  }

  func prompt(ofSurface surface: Int, in range: Range<Int>) -> TranscriptQuotedPrompt {
    let range = NSRange(range)
    switch self {
    case let .mounted(surfaces):
      return Self.prompt(in: surfaces[surface].transcriptText, range: range) {
        surfaces[surface].transcriptPlainText(in: range)
      }
    case let .cached(texts):
      return Self.prompt(in: texts[surface], range: range) { Self.plainText(of: texts[surface], in: range) }
    case let .projected(prompts):
      return prompts[surface].subprompt(in: range)
    }
  }

  private static func prompt(
    in text: NSAttributedString, range: NSRange, plain: () -> String
  ) -> TranscriptQuotedPrompt {
    let quoted = TranscriptQuoteBadgeText.prompt(in: text.attributedSubstring(from: clamped(range, in: text)))
    return quoted.quotes.isEmpty ? TranscriptQuotedPrompt(text: plain()) : quoted
  }

  private static func plainText(of text: NSAttributedString, in range: NSRange) -> String {
    (text.string as NSString).substring(with: clamped(range, in: text))
  }

  private static func clamped(_ range: NSRange, in text: NSAttributedString) -> NSRange {
    let location = min(max(0, range.location), text.length)
    return NSRange(location: location, length: min(max(0, range.length), text.length - location))
  }
}

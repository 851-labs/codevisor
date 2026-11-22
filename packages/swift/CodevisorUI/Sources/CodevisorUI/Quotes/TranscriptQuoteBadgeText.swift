import Foundation
import StreamMarkdown
import TranscriptKit
#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

public enum TranscriptQuoteBadgeText {
  public static func attributedString(
    _ prompt: TranscriptQuotedPrompt, attributes: [NSAttributedString.Key: Any], linksQuotes: Bool = false
  ) -> NSAttributedString {
    let result = NSMutableAttributedString(string: prompt.text, attributes: attributes)
    let font = attributes[.font] as? OSFont ?? defaultFont
    let color = attributes[.foregroundColor] as? OSColor ?? defaultColor
    for (index, location) in markerLocations(in: prompt.text).enumerated() {
      let range = NSRange(location: location, length: 1)
      let badge = TranscriptQuoteBadgeAttachment(quote: prompt.quotes[index], font: font, color: color)
      result.addAttribute(.attachment, value: badge, range: range)
      result.addAttribute(.streamMarkdownPlainText, value: "“\(badge.quote.text)”", range: range)
      if linksQuotes { result.addAttribute(.link, value: TranscriptQuoteLink.url(toQuoteAt: index), range: range) }
    }
    return result
  }

  public static func prompt(in text: NSAttributedString) -> TranscriptQuotedPrompt {
    let kept = NSMutableString(string: text.string)
    var quotes: [TranscriptQuote] = []
    for location in markerLocations(in: text.string).reversed() {
      if let badge = text.attribute(.attachment, at: location, effectiveRange: nil) as? TranscriptQuoteBadgeAttachment {
        quotes.insert(badge.quote, at: 0)
      } else {
        kept.deleteCharacters(in: NSRange(location: location, length: 1))
      }
    }
    return TranscriptQuotedPrompt(text: kept as String, quotes: quotes)
  }

  private static func markerLocations(in text: String) -> [Int] {
    let characters = text as NSString
    return (0..<characters.length).filter { characters.character(at: $0) == markerUnit }
  }

  private static let markerUnit: unichar = 0xFFFC

  #if canImport(AppKit)
    private static var defaultFont: NSFont { .preferredFont(forTextStyle: .body) }
    private static var defaultColor: NSColor { .labelColor }
  #elseif canImport(UIKit)
    private static var defaultFont: UIFont { .preferredFont(forTextStyle: .body) }
    private static var defaultColor: UIColor { .label }
  #endif
}

import Foundation

public struct TranscriptQuotedPromptEdit: Equatable, Sendable {
  public let id: UUID
  public let range: NSRange
  public let replacement: TranscriptQuotedPrompt

  public init(id: UUID = UUID(), range: NSRange, replacement: TranscriptQuotedPrompt) {
    self.id = id
    self.range = range
    self.replacement = replacement
  }

  public static func insertingQuote(
    _ quote: TranscriptQuote, into prompt: TranscriptQuotedPrompt, at location: Int
  ) -> TranscriptQuotedPromptEdit {
    let text = prompt.text as NSString
    let location = min(max(0, location), text.length)
    let leading = needsSpace(in: text, at: location - 1) ? " " : ""
    let trailing = needsSpace(in: text, at: location) || location == text.length ? " " : ""
    let replacement = TranscriptQuotedPrompt(
      text: leading + TranscriptQuotedPrompt.quoteMarker + trailing, quotes: [quote])
    return TranscriptQuotedPromptEdit(range: NSRange(location: location, length: 0), replacement: replacement)
  }

  public static func insertingQuotes(
    _ quotes: [TranscriptQuote], into prompt: TranscriptQuotedPrompt, at location: Int
  ) -> TranscriptQuotedPromptEdit {
    let start = min(max(0, location), (prompt.text as NSString).length)
    var working = prompt
    var caret = start
    for quote in quotes {
      let edit = insertingQuote(quote, into: working, at: caret)
      working = edit.applied(to: working)
      caret = edit.selectionAfter.location
    }
    let inserted = working.subprompt(in: NSRange(location: start, length: caret - start))
    return TranscriptQuotedPromptEdit(range: NSRange(location: start, length: 0), replacement: inserted)
  }

  public func applied(to prompt: TranscriptQuotedPrompt) -> TranscriptQuotedPrompt {
    prompt.replacingCharacters(in: range, with: replacement)
  }

  public var selectionAfter: NSRange {
    NSRange(location: range.location + (replacement.text as NSString).length, length: 0)
  }

  private static func needsSpace(in text: NSString, at index: Int) -> Bool {
    guard index >= 0, index < text.length else { return false }
    guard let scalar = Unicode.Scalar(text.character(at: index)) else { return true }
    return !CharacterSet.whitespacesAndNewlines.contains(scalar)
  }
}

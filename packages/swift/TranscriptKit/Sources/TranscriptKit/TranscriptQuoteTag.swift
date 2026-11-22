import Foundation

struct TranscriptQuoteTag {
  let quote: TranscriptQuote
  let remainder: Substring
  let isLegacyBlock: Bool

  static let opening = "<codevisor-quote"
  static let closing = "</codevisor-quote>"

  static func inline(_ quote: TranscriptQuote) -> String {
    let attributes = [
      ("role", quote.role.rawValue),
      ("message", quote.messageID),
      ("sent", quote.sentAt?.formatted(.iso8601)),
    ]
    let header = attributes.compactMap { name, value in value.map { "\(name)=\"\(escaped($0))\"" } }
    let body = quote.text.trimmingCharacters(in: .newlines)
    return "\(opening) \(header.joined(separator: " "))>\(body)\(closing)"
  }

  init?(parsing text: Substring, index: Int) {
    guard let header = text.prefixMatch(of: /<codevisor-quote((?: [a-z]+="[^"]*")*)>/) else { return nil }

    let afterHeader = text[header.range.upperBound...]
    let isLegacyBlock = afterHeader.hasPrefix("\n")
    let body = isLegacyBlock ? afterHeader.dropFirst() : afterHeader
    guard let close = body.range(of: isLegacyBlock ? "\n" + Self.closing : Self.closing),
      let quote = Self.quote(attributes: header.output.1, text: String(body[..<close.lowerBound]), index: index)
    else { return nil }

    self.quote = quote
    self.remainder = body[close.upperBound...]
    self.isLegacyBlock = isLegacyBlock
  }

  private static func quote(attributes header: Substring, text: String, index: Int) -> TranscriptQuote? {
    let attributes = attributes(in: header)
    guard let role = attributes["role"].flatMap(TranscriptQuote.Role.init(rawValue:)),
      let messageID = attributes["message"]
    else { return nil }

    let sentAt = attributes["sent"].flatMap { try? Date($0, strategy: .iso8601) }
    return TranscriptQuote(id: "quote-\(index)", text: text, messageID: messageID, role: role, sentAt: sentAt)
  }

  private static func attributes(in header: Substring) -> [String: String] {
    let pairs = header.matches(of: /([a-z]+)="([^"]*)"/).map { (String($0.output.1), unescaped(String($0.output.2))) }
    return Dictionary(pairs) { first, _ in first }
  }

  private static func escaped(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
  }

  private static func unescaped(_ value: String) -> String {
    value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
  }
}

struct TranscriptQuoteTagReader {
  private(set) var prompt = TranscriptQuotedPrompt()

  init(promptText: String) {
    var text = ""
    var quotes: [TranscriptQuote] = []
    var rest = Substring(promptText)
    while let opening = rest.range(of: TranscriptQuoteTag.opening) {
      text += rest[..<opening.lowerBound]
      guard let tag = TranscriptQuoteTag(parsing: rest[opening.lowerBound...], index: quotes.count) else {
        text += rest[opening]
        rest = rest[opening.upperBound...]
        continue
      }
      text += TranscriptQuotedPrompt.quoteMarker
      quotes.append(tag.quote)
      rest = tag.isLegacyBlock ? Self.joiningLegacyBlock(tag.remainder, into: &text) : tag.remainder
    }
    prompt = TranscriptQuotedPrompt(text: text + rest, quotes: quotes)
  }

  private static func joiningLegacyBlock(_ remainder: Substring, into text: inout String) -> Substring {
    let rest = remainder.drop { $0 == "\n" }
    if rest.hasPrefix(TranscriptQuoteTag.opening) {
      text += " "
    } else if !rest.isEmpty {
      text += "\n"
    }
    return rest
  }
}

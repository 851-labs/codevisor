import Foundation

public struct TranscriptQuotedPrompt: Equatable, Sendable {
  public var quotes: [TranscriptQuote]
  public var text: String

  public init(quotes: [TranscriptQuote], text: String) {
    self.quotes = quotes
    self.text = text
  }

  public init(promptText: String) {
    var rest = Substring(promptText)
    var quotes: [TranscriptQuote] = []
    while let (quote, remainder) = Self.leadingQuote(in: rest, index: quotes.count) {
      quotes.append(quote)
      rest = remainder
    }
    self.init(quotes: quotes, text: quotes.isEmpty ? promptText : String(rest))
  }

  public var promptText: String {
    (quotes.map(Self.block) + [text]).filter { !$0.isEmpty }.joined(separator: Self.blockSeparator)
  }

  private static let opening = "<codevisor-quote"
  private static let closing = "\n</codevisor-quote>"
  private static let blockSeparator = "\n\n"

  private static func block(_ quote: TranscriptQuote) -> String {
    let attributes = [
      ("role", quote.role.rawValue),
      ("message", quote.messageID),
      ("sent", quote.sentAt?.formatted(.iso8601)),
    ]
    let header = attributes.compactMap { name, value in value.map { "\(name)=\"\(escaped($0))\"" } }
    return "\(opening) \(header.joined(separator: " "))>\n\(quote.text)\(closing)"
  }

  private static func leadingQuote(in text: Substring, index: Int) -> (TranscriptQuote, Substring)? {
    guard text.hasPrefix(opening + " "), let headerEnd = text.firstIndex(of: "\n") else { return nil }
    let header = text[..<headerEnd]
    guard header.hasSuffix(">") else { return nil }

    let body = text[text.index(after: headerEnd)...]
    guard let close = body.range(of: closing) else { return nil }
    guard let quote = quote(header: header, text: String(body[..<close.lowerBound]), index: index) else {
      return nil
    }

    return (quote, trimmingBlockSeparator(body[close.upperBound...]))
  }

  private static func quote(header: Substring, text: String, index: Int) -> TranscriptQuote? {
    let attributes = attributes(in: header)
    guard let role = attributes["role"].flatMap(TranscriptQuote.Role.init(rawValue:)),
      let messageID = attributes["message"]
    else { return nil }

    let sentAt = attributes["sent"].flatMap { try? Date($0, strategy: .iso8601) }
    return TranscriptQuote(
      id: TranscriptQuote.sendFlightID(at: index), text: text, messageID: messageID, role: role, sentAt: sentAt)
  }

  private static func attributes(in header: Substring) -> [String: String] {
    let pattern = /([a-z]+)="([^"]*)"/
    let pairs = header.matches(of: pattern).map { (String($0.output.1), unescaped(String($0.output.2))) }
    return Dictionary(pairs) { first, _ in first }
  }

  private static func trimmingBlockSeparator(_ text: Substring) -> Substring {
    if text.hasPrefix(blockSeparator) { return text.dropFirst(blockSeparator.count) }
    if text.hasPrefix("\n") { return text.dropFirst() }
    return text
  }

  private static func escaped(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
  }

  private static func unescaped(_ value: String) -> String {
    value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
  }
}

extension ConversationItem {
  var presentingQuotes: ConversationItem {
    guard case let .user(message) = self else { return self }
    return .user(message.presentingQuotes)
  }
}

extension UserMessage {
  public var presentingQuotes: UserMessage {
    let prompt = TranscriptQuotedPrompt(promptText: text)
    guard !prompt.quotes.isEmpty else { return self }

    var message = self
    message.text = prompt.text
    message.quotes = prompt.quotes
    return message
  }
}

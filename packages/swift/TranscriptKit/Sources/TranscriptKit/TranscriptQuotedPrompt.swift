import Foundation

public struct TranscriptQuotedPrompt: Equatable, Sendable {
  public static let quoteMarker = "\u{FFFC}"

  public private(set) var text: String
  public private(set) var quotes: [TranscriptQuote]

  public init(text: String = "", quotes: [TranscriptQuote] = []) {
    let markers = Self.markerCount(in: text)
    self.text = markers > quotes.count ? Self.droppingMarkers(after: quotes.count, in: text) : text
    self.quotes = Array(quotes.prefix(markers))
  }

  public init(promptText: String) {
    self = TranscriptQuoteTagReader(promptText: promptText).prompt
  }

  public var promptText: String {
    replacingQuotes(with: TranscriptQuoteTag.inline)
  }

  public var isEmpty: Bool {
    text.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
  }

  public var trimmed: TranscriptQuotedPrompt {
    TranscriptQuotedPrompt(text: text.trimmingCharacters(in: .whitespacesAndNewlines), quotes: quotes)
  }

  public var readableText: String {
    replacingQuotes { "“\($0.text)”" }
  }

  public func replacingQuotes(with render: (TranscriptQuote) -> String) -> String {
    guard !quotes.isEmpty else { return text }

    var remaining = quotes.makeIterator()
    var result = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      guard scalar == Self.markerScalar else {
        result.append(scalar)
        continue
      }
      result.append(contentsOf: (remaining.next().map(render) ?? "").unicodeScalars)
    }
    return String(result)
  }

  public func replacingCharacters(in range: NSRange, with replacement: TranscriptQuotedPrompt) -> TranscriptQuotedPrompt
  {
    let range = clamped(range)
    let source = text as NSString
    let before = Self.markerCount(in: source.substring(to: range.location))
    let removed = Self.markerCount(in: source.substring(with: range))
    let kept = quotes.prefix(before) + replacement.quotes + quotes.dropFirst(before + removed)
    return TranscriptQuotedPrompt(
      text: source.replacingCharacters(in: range, with: replacement.text), quotes: Array(kept))
  }

  public func appending(_ other: TranscriptQuotedPrompt) -> TranscriptQuotedPrompt {
    TranscriptQuotedPrompt(text: text + other.text, quotes: quotes + other.quotes)
  }

  public func subprompt(in range: NSRange) -> TranscriptQuotedPrompt {
    let range = clamped(range)
    let source = text as NSString
    let before = Self.markerCount(in: source.substring(to: range.location))
    let slice = source.substring(with: range)
    return TranscriptQuotedPrompt(text: slice, quotes: Array(quotes.dropFirst(before)))
  }

  public static func markerCount(in text: some StringProtocol) -> Int {
    var text = String(text)
    text.makeContiguousUTF8()
    return text.utf8.withContiguousStorageIfAvailable(markerCount(inUTF8:))
      ?? text.unicodeScalars.lazy.filter { $0 == markerScalar }.count
  }

  private func clamped(_ range: NSRange) -> NSRange {
    let length = (text as NSString).length
    let location = min(max(0, range.location), length)
    return NSRange(location: location, length: min(max(0, range.length), length - location))
  }

  private static func markerCount(inUTF8 bytes: UnsafeBufferPointer<UInt8>) -> Int {
    guard let base = bytes.baseAddress else { return 0 }

    var count = 0
    var offset = 0
    while offset < bytes.count, let hit = memchr(base + offset, Int32(markerUTF8[0]), bytes.count - offset) {
      let index = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
      if bytes[index...].starts(with: markerUTF8) { count += 1 }
      offset = index + 1
    }
    return count
  }

  private static func droppingMarkers(after kept: Int, in text: String) -> String {
    var seen = 0
    let scalars = text.unicodeScalars.filter { scalar in
      guard scalar == markerScalar else { return true }
      seen += 1
      return seen <= kept
    }
    return String(String.UnicodeScalarView(scalars))
  }

  private static let markerScalar: Unicode.Scalar = "\u{FFFC}"
  private static let markerUTF8: [UInt8] = [0xEF, 0xBF, 0xBC]
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

  public var quotedPrompt: TranscriptQuotedPrompt {
    TranscriptQuotedPrompt(text: text, quotes: quotes)
  }
}

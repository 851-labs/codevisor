import Foundation

enum TranscriptEventParser {
  private static let unknownType = "unknown"

  static func events(in text: String) -> [TranscriptEvent] {
    let range = NSRange(text.startIndex..., in: text)
    let events = blockPattern.matches(in: text, range: range).compactMap { event(from: $0, in: text) }
    guard events.isEmpty else { return events }

    return [TranscriptEvent(type: unknownType, body: text.trimmingCharacters(in: .whitespacesAndNewlines))]
  }

  private static func event(from match: NSTextCheckingResult, in text: String) -> TranscriptEvent? {
    guard let header = substring(match.range(at: 1), in: text),
      let body = substring(match.range(at: 2), in: text)
    else { return nil }

    var attributes = attributes(in: header)
    let type = attributes.removeValue(forKey: "type") ?? unknownType
    return TranscriptEvent(type: type, attributes: attributes, body: unescapedBody(body))
  }

  private static func attributes(in header: String) -> [String: String] {
    let range = NSRange(header.startIndex..., in: header)
    var attributes: [String: String] = [:]
    for match in attributePattern.matches(in: header, range: range) {
      guard let name = substring(match.range(at: 1), in: header),
        let value = substring(match.range(at: 2), in: header)
      else { continue }
      attributes[name] = unescapedAttribute(value)
    }
    return attributes
  }

  private static func substring(_ range: NSRange, in text: String) -> String? {
    Range(range, in: text).map { String(text[$0]) }
  }

  private static func unescapedAttribute(_ value: String) -> String {
    value.replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&amp;", with: "&")
  }

  private static func unescapedBody(_ body: String) -> String {
    body.replacingOccurrences(of: "<\\/", with: "</").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let blockPattern = try! NSRegularExpression(
    pattern: #"<codevisor-event\b([^>]*)>(.*?)</codevisor-event>"#,
    options: [.dotMatchesLineSeparators]
  )

  private static let attributePattern = try! NSRegularExpression(
    pattern: #"([A-Za-z][\w-]*)="([^"]*)""#
  )
}

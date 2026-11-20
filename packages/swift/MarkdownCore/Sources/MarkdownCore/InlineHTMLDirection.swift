import Foundation

struct InlineHTMLDirection {
  private struct Opening {
    let tag: String
    let closer: String?
  }

  private var open: [Opening] = []

  mutating func reset() {
    open.removeAll(keepingCapacity: true)
  }

  mutating func text(for html: String) -> String {
    guard let tag = Self.tag(in: html) else { return html }
    if tag.isClosing { return close(tag.name, html: html) }
    guard Self.pairedTags.contains(tag.name) else { return html }

    let controls = Self.controls(tag: tag.name, direction: tag.direction)
    open.append(Opening(tag: tag.name, closer: controls?.closer))
    return controls?.opener ?? html
  }

  mutating func unclosedText() -> String {
    defer { open.removeAll(keepingCapacity: true) }
    return open.reversed().compactMap(\.closer).joined()
  }

  private mutating func close(_ name: String, html: String) -> String {
    guard let index = open.lastIndex(where: { $0.tag == name }) else { return html }
    let closed = open[index...]
    open.removeSubrange(index...)
    let closers = closed.reversed().compactMap(\.closer).joined()
    return closed.first?.closer == nil ? closers + html : closers
  }

  private static let pairedTags: Set<String> = ["bdi", "bdo", "span"]

  private static func controls(tag: String, direction: String?) -> (opener: String, closer: String)? {
    let isolate = isolateOpener(direction)
    switch tag {
    case "bdi": return (isolate ?? firstStrongIsolate, popIsolate)
    case "span": return isolate.map { ($0, popIsolate) }
    case "bdo": return override(direction) ?? (firstStrongIsolate, popIsolate)
    default: return nil
    }
  }

  private static func isolateOpener(_ direction: String?) -> String? {
    switch direction {
    case "rtl": "\u{2067}"
    case "ltr": "\u{2066}"
    case "auto": firstStrongIsolate
    default: nil
    }
  }

  private static func override(_ direction: String?) -> (opener: String, closer: String)? {
    switch direction {
    case "rtl": ("\u{2067}\u{202E}", "\u{202C}" + popIsolate)
    case "ltr": ("\u{2066}\u{202D}", "\u{202C}" + popIsolate)
    default: nil
    }
  }

  private static let firstStrongIsolate = "\u{2068}"
  private static let popIsolate = "\u{2069}"

  private struct Tag {
    let name: String
    let isClosing: Bool
    let direction: String?
  }

  private static let tagPattern = try! NSRegularExpression(
    pattern: #"^<(/?)([A-Za-z][A-Za-z0-9-]*)((?:\s+[^\s"'>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*>$"#
  )

  private static let dirPattern = try! NSRegularExpression(
    pattern: #"(?:^|\s)dir\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#, options: .caseInsensitive
  )

  private static func tag(in html: String) -> Tag? {
    let range = NSRange(html.startIndex..., in: html)
    guard let match = tagPattern.firstMatch(in: html, range: range),
      let name = substring(html, match.range(at: 2)),
      let attributes = substring(html, match.range(at: 3))
    else { return nil }
    let isClosing = match.range(at: 1).length > 0
    if isClosing, !attributes.isEmpty { return nil }
    return Tag(name: name.lowercased(), isClosing: isClosing, direction: direction(in: attributes))
  }

  private static func direction(in attributes: String) -> String? {
    let range = NSRange(attributes.startIndex..., in: attributes)
    guard let match = dirPattern.firstMatch(in: attributes, range: range) else { return nil }
    return (1...3).lazy.compactMap { substring(attributes, match.range(at: $0)) }.first?
      .trimmingCharacters(in: .whitespaces).lowercased()
  }

  private static func substring(_ string: String, _ range: NSRange) -> String? {
    guard range.location != NSNotFound, let bounds = Range(range, in: string) else { return nil }
    return String(string[bounds])
  }
}

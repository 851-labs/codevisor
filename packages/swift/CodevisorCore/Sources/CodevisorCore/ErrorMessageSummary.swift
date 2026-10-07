import Foundation

/// A harness error as one readable line, with the full text kept as details
/// when it is longer. Harnesses pass through what their providers report,
/// which can be a whole validation dump or response body; the line is what
/// a person reads, the details are what a person debugs with.
public struct ErrorMessageSummary: Equatable, Sendable {
  public let summary: String
  /// The full message, when the summary leaves something out.
  public let details: String?

  static let maximumLength = 160

  public init(_ message: String) {
    let full = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = Self.headline(full)
    self.summary = summary
    self.details = summary == full ? nil : full
  }

  /// The text before the first line break or dumped value (`{…}` / `[…]`),
  /// without the label that introduced the value ("…: Value: {"), capped
  /// to a line.
  private static func headline(_ message: String) -> String {
    guard let stop = message.rangeOfCharacter(from: CharacterSet(charactersIn: "\n{[")) else {
      return capped(message)
    }
    var line = String(message[..<stop.lowerBound]).trimmingCharacters(in: .whitespaces)
    if line.hasSuffix(":") {
      line = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
      // "Type validation failed: Value" — a one-word label names the dump.
      if let separator = line.range(of: ": ", options: .backwards) {
        let label = line[separator.upperBound...]
        if !label.isEmpty, !label.contains(" ") { line = String(line[..<separator.lowerBound]) }
      }
    } else if line.hasSuffix(".") || line.hasSuffix(",") {
      line = String(line.dropLast())
    }
    // Nothing before the dump: show the start of the message itself.
    return capped(line.isEmpty ? message.replacingOccurrences(of: "\n", with: " ") : line)
  }

  private static func capped(_ line: String) -> String {
    guard line.count > maximumLength else { return line }
    return String(line.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }
}

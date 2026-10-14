import Foundation

public struct ErrorMessageSummary: Equatable, Sendable {
  public let summary: String
  public let details: String?

  static let maximumLength = 160

  public init(_ message: String) {
    let full = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = Self.headline(full)
    self.summary = summary
    self.details = summary == full ? nil : full
  }

  private static func headline(_ message: String) -> String {
    guard let stop = message.rangeOfCharacter(from: CharacterSet(charactersIn: "\n{[")) else {
      return capped(message)
    }
    let line = Self.withoutDumpLabel(
      String(message[..<stop.lowerBound]).trimmingCharacters(in: .whitespaces))
    return capped(line.isEmpty ? message.replacingOccurrences(of: "\n", with: " ") : line)
  }

  private static func withoutDumpLabel(_ prefix: String) -> String {
    var line = prefix
    if line.hasSuffix(":") {
      line = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
      if let separator = line.range(of: ": ", options: .backwards) {
        let label = line[separator.upperBound...]
        if !label.isEmpty, !label.contains(" ") { line = String(line[..<separator.lowerBound]) }
      }
    } else if line.hasSuffix(".") || line.hasSuffix(",") {
      line = String(line.dropLast())
    }
    return line
  }

  private static func capped(_ line: String) -> String {
    guard line.count > maximumLength else { return line }
    return String(line.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }
}

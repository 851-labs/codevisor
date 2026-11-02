import Foundation
import MarkdownCore

public struct TranscriptBotCallout: Equatable, Sendable {
  private static let labels = [
    "NOTE": "Note", "TIP": "Tip", "IMPORTANT": "Important", "WARNING": "Warning", "CAUTION": "Caution",
  ]

  public let label: String
  public let markdown: String
  public let blocks: [MarkdownBlock]

  init?(quote text: String) {
    var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    guard let first = lines.first, let label = Self.label(inMarker: Self.unquoted(first)) else { return nil }

    lines.removeFirst()
    self.label = label
    markdown = TranscriptBotMessageContent.bubbleMarkdown(lines.map(Self.unquoted).joined(separator: "\n"))
    blocks = MarkdownParser().parse(markdown)
  }

  private static func label(inMarker line: String) -> String? {
    let marker = line.trimmingCharacters(in: .whitespaces)
    guard marker.hasPrefix("[!"), marker.hasSuffix("]") else { return nil }
    return labels[String(marker.dropFirst(2).dropLast()).uppercased()]
  }

  private static func unquoted(_ line: String) -> String {
    let content = line.drop { $0 == " " }
    guard content.hasPrefix(">") else { return line }
    let rest = content.dropFirst()
    return String(rest.first == " " ? rest.dropFirst() : rest)
  }
}

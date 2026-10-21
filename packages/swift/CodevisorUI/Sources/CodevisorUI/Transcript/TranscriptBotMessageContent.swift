import Foundation
import TranscriptKit

public struct TranscriptBotMessageContent {
  public let text: String
  public let markdown: String
  public let files: [PreviewFile]

  public init(_ message: TranscriptBotMessage) {
    let segments = assistantMarkdownSegments(message.text, attachments: message.attachments)
    text = Self.markdown(in: segments).trimmingCharacters(in: .whitespacesAndNewlines)
    markdown = Self.bubbleMarkdown(text)
    files = Self.unique(Self.files(in: segments))
  }

  static func bubbleMarkdown(_ text: String) -> String {
    var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var fence: String?
    for index in lines.indices {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if let open = fence {
        if trimmed.hasPrefix(open) { fence = nil }
        continue
      }
      if let open = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
        fence = open
        continue
      }
      lines[index] = lines[index].replacingOccurrences(
        of: #"^(\s*)[•◦▪‣]\s+"#, with: "$1- ", options: .regularExpression)
      let next = lines.index(after: index)
      guard !trimmed.isEmpty, next < lines.endIndex,
        !lines[next].trimmingCharacters(in: .whitespaces).isEmpty,
        !lines[index].hasSuffix("  "), !lines[index].hasSuffix("\\")
      else { continue }
      lines[index] += "  "
    }
    return lines.joined(separator: "\n")
  }

  private static func markdown(in segments: [AssistantMarkdownSegment]) -> String {
    segments.map { segment in
      guard case let .markdown(text) = segment else { return "" }
      return text
    }.joined()
  }

  private static func files(in segments: [AssistantMarkdownSegment]) -> [PreviewFile] {
    segments.compactMap { segment in
      guard case let .file(file, _) = segment else { return nil }
      return file
    }
  }

  private static func unique(_ files: [PreviewFile]) -> [PreviewFile] {
    var seen = Set<String>()
    return files.filter { seen.insert($0.id).inserted }
  }
}

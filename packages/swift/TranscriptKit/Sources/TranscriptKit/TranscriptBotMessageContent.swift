import Foundation
import MarkdownCore

public struct TranscriptBotMessageContent: Equatable, Sendable {
  public let text: String
  public let markdown: String
  public let files: [PreviewFile]
  public let blocks: [MarkdownBlock]

  public init(_ message: TranscriptBotMessage) {
    let segments = assistantMarkdownSegments(message.text, attachments: message.attachments)
    text = Self.markdown(in: segments).trimmingCharacters(in: .whitespacesAndNewlines)
    markdown = Self.bubbleMarkdown(text)
    files = Self.unique(Self.files(in: segments))
    blocks = MarkdownParser().parse(markdown)
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

final class TranscriptBotMessageContentCache: @unchecked Sendable {
  private struct Entry {
    let text: String
    let attachments: [Attachment]
    let content: TranscriptBotMessageContent
  }

  static let shared = TranscriptBotMessageContentCache()
  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var order: [String] = []
  private let limit: Int

  init(limit: Int = 2_048) {
    self.limit = max(1, limit)
  }

  func content(for message: TranscriptBotMessage) -> TranscriptBotMessageContent {
    if let entry = lock.withLock({ entries[message.id] }),
      entry.text == message.text, entry.attachments == message.attachments
    {
      return entry.content
    }
    let content = TranscriptBotMessageContent(message)
    lock.withLock {
      if entries.updateValue(
        Entry(text: message.text, attachments: message.attachments, content: content), forKey: message.id) == nil
      {
        order.append(message.id)
      }
      if order.count > limit {
        let evicted = order.prefix(order.count - limit / 2)
        for id in evicted { entries.removeValue(forKey: id) }
        order.removeFirst(evicted.count)
      }
    }
    return content
  }
}

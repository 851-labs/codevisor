import Foundation
import MarkdownCore

enum TranscriptBotMessageParts {
  private enum Part: Equatable {
    case text(String)
    case block(String)
    case files([PreviewFile])

    var hasContent: Bool {
      switch self {
      case let .text(text), let .block(text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      case let .files(files): !files.isEmpty
      }
    }

    var isFiles: Bool {
      if case .files = self { return true }
      return false
    }
  }

  private static let cache = Cache()

  static func parts(of message: TranscriptBotMessage) -> [TranscriptBotMessage] {
    guard message.sender == .bot, !message.isTranscriptMarkdown else { return [message] }

    let parts = cache.parts(for: message) { split(message) }
    guard parts.count > 1 || parts.first?.isFiles == true else { return [message] }

    return parts.enumerated().map { index, part in
      self.message(for: part, at: index, of: message)
    }
  }

  private static func split(_ message: TranscriptBotMessage) -> [Part] {
    var parts: [Part] = []
    var seenFiles = Set<String>()
    for segment in assistantMarkdownSegments(message.text, attachments: message.attachments) {
      switch segment {
      case let .markdown(source):
        parts += markdownParts(in: source)
      case let .file(file, _) where seenFiles.insert(file.id).inserted:
        appendFile(file, to: &parts)
      case .file:
        continue
      }
    }
    return parts
  }

  private static func appendFile(_ file: PreviewFile, to parts: inout [Part]) {
    guard case let .files(files)? = parts.last else {
      parts.append(.files([file]))
      return
    }
    parts[parts.count - 1] = .files(files + [file])
  }

  private static func markdownParts(in markdown: String) -> [Part] {
    let source = TranscriptMarkdownBlocks.normalized(markdown)
    var parts: [Part] = []
    var text: Range<String.Index>?
    for block in TranscriptMarkdownBlocks.blocks(in: source) {
      let standalone = standalonePart(block, in: source)
      guard standalone != nil || block.kind.splitsParts else {
        text = text.map { $0.lowerBound..<block.source.upperBound } ?? block.source
        continue
      }
      if let text { parts.append(.text(String(source[text]))) }
      text = nil
      if let standalone { parts.append(standalone) }
    }
    if let text { parts.append(.text(String(source[text]))) }
    return parts.filter(\.hasContent)
  }

  private static func standalonePart(_ block: TranscriptMarkdownBlocks.Block, in source: String) -> Part? {
    guard block.kind.canStandAlone else { return nil }

    let text = String(source[block.source])
    let parsed = MarkdownParser().parse(text)
    guard parsed.count == 1 else { return nil }
    if let file = TranscriptBotFileReference.file(in: parsed[0]) { return .files([file]) }
    return TranscriptBotPartStyle(blocks: parsed).standsAlone ? .block(text) : nil
  }

  private static func message(for part: Part, at index: Int, of whole: TranscriptBotMessage) -> TranscriptBotMessage {
    let id = "\(whole.id):\(index)"
    switch part {
    case let .text(text), let .block(text):
      return TranscriptBotMessage(
        id: id, sender: .bot, text: text, attachments: [], sentAt: whole.sentAt, delivery: nil, files: [],
        isTranscriptMarkdown: false, side: whole.side, author: whole.author)
    case let .files(files):
      return TranscriptBotMessage(
        id: id, sender: .bot, text: "", attachments: [], sentAt: whole.sentAt, delivery: nil, files: files,
        isTranscriptMarkdown: true, side: whole.side, author: whole.author)
    }
  }

  private final class Cache: @unchecked Sendable {
    private struct Key: Hashable {
      let text: String
      let attachments: [Attachment]
    }

    private let lock = NSLock()
    private var entries: [Key: [Part]] = [:]
    private let limit = 512

    func parts(for message: TranscriptBotMessage, split: () -> [Part]) -> [Part] {
      let key = Key(text: message.text, attachments: message.attachments)
      if let cached = lock.withLock({ entries[key] }) { return cached }
      let parts = split()
      lock.withLock {
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[key] = parts
      }
      return parts
    }
  }
}

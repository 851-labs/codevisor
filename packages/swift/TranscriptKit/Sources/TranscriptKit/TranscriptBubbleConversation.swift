import Foundation

enum TranscriptBubbleConversation {
  static func make(_ input: TranscriptProjectionInput) -> TranscriptBotConversation {
    var messages: [TranscriptBotMessage] = []
    var seenUserIDs = Set<UUID>()
    let items = input.settledConversation + [input.activeItem].compactMap(\.self)
    for (index, item) in items.enumerated() {
      switch item {
      case .user:
        guard let prompt = item.userPrompt, seenUserIDs.insert(prompt.id).inserted else { continue }
        messages.append(userMessage(prompt, delivery: nil, sentAt: answerStart(after: index, in: items)))
      case let .assistant(message):
        messages += assistantMessages(message)
      }
    }
    for outgoing in input.outgoingMessages where seenUserIDs.insert(outgoing.id).inserted {
      messages.append(userMessage(outgoing, delivery: input.deliveries[outgoing.id], sentAt: nil))
    }
    return TranscriptBotConversation(messages: messages, isWorking: isWorking(input))
  }

  private static func isWorking(_ input: TranscriptProjectionInput) -> Bool {
    guard case let .assistant(message)? = input.activeItem else { return input.pendingUserMessage != nil }
    return message.turn.isGenerating && message.turn.finalText == nil
  }

  private static func answerStart(after index: Int, in items: [ConversationItem]) -> Date? {
    for item in items[(index + 1)...] {
      if case let .assistant(message) = item { return message.turn.startedAt }
    }
    return nil
  }

  private static func userMessage(
    _ message: UserMessage, delivery: TranscriptDelivery?, sentAt: Date?
  ) -> TranscriptBotMessage {
    TranscriptBotMessage(
      id: message.id.uuidString.lowercased(), sender: .user, text: message.text, attachments: message.attachments,
      sentAt: sentAt, delivery: delivery)
  }

  private static func assistantMessages(_ message: AssistantMessage) -> [TranscriptBotMessage] {
    let turn = message.turn
    guard let (_, markdown) = TranscriptAssistantRowProjection.responseText(turn) else { return [] }
    let sentAt = turn.endedAt ?? turn.startedAt
    let segments = assistantMarkdownSegments(
      markdown, attachments: turn.attachments, localImagesPendingCapture: turn.isGenerating)
    var bubbles: [(text: String, files: [PreviewFile])] = []
    for segment in segments {
      switch segment {
      case let .markdown(source):
        bubbles += TranscriptBubbleSplitter.bubbles(in: source).map { (text: $0, files: []) }
      case let .file(file, _):
        bubbles.append((text: "", files: [file]))
      }
    }
    return bubbles.enumerated().map { index, bubble in
      TranscriptBotMessage(
        id: "\(message.id.uuidString.lowercased()):\(index)", sender: .bot, text: bubble.text, attachments: [],
        sentAt: sentAt, delivery: nil, files: bubble.files, isTranscriptMarkdown: true)
    }
  }
}

enum TranscriptBubbleSplitter {
  private enum Kind {
    case paragraph
    case heading
    case list
    case quote
    case table
    case code(fence: String)
    case rule
  }

  private struct Block {
    var kind: Kind
    var lines: [Substring]
  }

  private static let cache = Cache()

  static func bubbles(in markdown: String) -> [String] {
    cache.bubbles(for: markdown) { split(markdown) }
  }

  private static func split(_ markdown: String) -> [String] {
    var bubbles: [String] = []
    var heading: String?
    for block in blocks(in: markdown) {
      let text = block.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      switch block.kind {
      case .rule:
        continue
      case .heading:
        heading = heading.map { "\($0)\n\n\(text)" } ?? text
      default:
        bubbles.append(heading.map { "\($0)\n\n\(text)" } ?? text)
        heading = nil
      }
    }
    if let heading { bubbles.append(heading) }
    return bubbles.filter { !$0.isEmpty }
  }

  private static func blocks(in markdown: String) -> [Block] {
    var blocks: [Block] = []
    var current: Block?
    var pendingBlank = false
    for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(
      separator: "\n", omittingEmptySubsequences: false)
    {
      if var block = current, case let .code(fence) = block.kind {
        block.lines.append(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(fence), trimmed.allSatisfy({ $0 == fence.first }) {
          blocks.append(block)
          current = nil
        } else {
          current = block
        }
        continue
      }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        pendingBlank = current != nil
        continue
      }
      if var block = current, continues(block, with: line, afterBlank: pendingBlank) {
        if pendingBlank { block.lines.append("") }
        block.lines.append(line)
        current = block
      } else {
        if let block = current { blocks.append(block) }
        let kind = kind(of: line)
        current = Block(kind: kind, lines: [line])
        if case .heading = kind {
          blocks.append(current!)
          current = nil
        } else if case .rule = kind {
          blocks.append(current!)
          current = nil
        }
      }
      pendingBlank = false
    }
    if let current { blocks.append(current) }
    return blocks
  }

  private static func continues(_ block: Block, with line: Substring, afterBlank: Bool) -> Bool {
    let indent = line.prefix { $0 == " " || $0 == "\t" }.count
    switch block.kind {
    case .list:
      if indent >= 2 { return true }
      if case .list = kind(of: line) { return true }
      return !afterBlank && startsParagraph(line)
    case .quote:
      if line.drop(while: { $0 == " " }).hasPrefix(">") { return true }
      return !afterBlank && startsParagraph(line)
    case .table:
      return !afterBlank && line.contains("|")
    case .paragraph:
      return !afterBlank && startsParagraph(line)
    case .heading, .code, .rule:
      return false
    }
  }

  private static func startsParagraph(_ line: Substring) -> Bool {
    if case .paragraph = kind(of: line) { return true }
    return false
  }

  private static func kind(of line: Substring) -> Kind {
    let indent = line.prefix { $0 == " " }.count
    guard indent < 4 else { return .paragraph }
    let trimmed = line.dropFirst(indent)
    if let fence = fence(opening: trimmed) { return .code(fence: fence) }
    if isRule(trimmed) { return .rule }
    if isHeading(trimmed) { return .heading }
    if trimmed.hasPrefix(">") { return .quote }
    if trimmed.hasPrefix("|") { return .table }
    if isListItem(trimmed) { return .list }
    return .paragraph
  }

  private static func fence(opening line: Substring) -> String? {
    for marker: Character in ["`", "~"] {
      let run = line.prefix { $0 == marker }.count
      if run >= 3 { return String(repeating: marker, count: run) }
    }
    return nil
  }

  private static func isRule(_ line: Substring) -> Bool {
    let compact = line.filter { $0 != " " }
    guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
    return compact.allSatisfy { $0 == first }
  }

  private static func isHeading(_ line: Substring) -> Bool {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return false }
    let rest = line.dropFirst(hashes)
    return rest.isEmpty || rest.first == " "
  }

  private static func isListItem(_ line: Substring) -> Bool {
    if let first = line.first, "-*+•".contains(first) {
      return line.dropFirst().first == " "
    }
    let digits = line.prefix(while: \.isNumber)
    guard (1...9).contains(digits.count) else { return false }
    let rest = line.dropFirst(digits.count)
    guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return false }
    return rest.dropFirst().first == " "
  }

  private final class Cache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: [String]] = [:]
    private let limit = 512

    func bubbles(for markdown: String, split: () -> [String]) -> [String] {
      if let cached = lock.withLock({ entries[markdown] }) { return cached }
      let bubbles = split()
      lock.withLock {
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[markdown] = bubbles
      }
      return bubbles
    }
  }
}

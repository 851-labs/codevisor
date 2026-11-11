import Foundation

struct BotMessageLog {
  private(set) var messages: [TranscriptBotMessage] = []
  private(set) var sequences: [Int] = []
  private(set) var revision: UInt64 = 0
  private var sources: [String: ServerBotMessage] = [:]
  private(set) var normalizedIDs: Set<String> = []

  var count: Int { messages.count }
  var isEmpty: Bool { messages.isEmpty }
  var firstSequence: Int? { sequences.first }
  var lastSequence: Int? { sequences.last }

  func contains(normalizedID: String) -> Bool {
    normalizedIDs.contains(normalizedID)
  }

  mutating func replace(with page: [ServerBotMessage]) {
    self = BotMessageLog(revision: revision &+ 1)
    for message in page.sorted(by: { $0.sequence < $1.sequence }) {
      insert(message)
    }
  }

  mutating func prepend(_ older: [ServerBotMessage]) {
    let fresh = older.filter { sources[$0.id] == nil }
    guard !fresh.isEmpty else { return }

    for message in fresh {
      insert(message)
    }
    revision &+= 1
  }

  mutating func upsert(_ message: ServerBotMessage) {
    guard sources[message.id] != message else { return }

    if sources[message.id] != nil {
      remove(id: message.id)
    }
    insert(message)
    revision &+= 1
  }

  private init(revision: UInt64) {
    self.revision = revision
  }

  init() {}

  private mutating func insert(_ message: ServerBotMessage) {
    let index = insertionIndex(for: message.sequence)
    messages.insert(Self.transcriptMessage(message), at: index)
    sequences.insert(message.sequence, at: index)
    sources[message.id] = message
    normalizedIDs.insert(message.id.lowercased())
  }

  private func insertionIndex(for sequence: Int) -> Int {
    guard let last = sequences.last, last > sequence else { return sequences.endIndex }

    return sequences.lastIndex { $0 <= sequence }.map { $0 + 1 } ?? 0
  }

  private mutating func remove(id: String) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }

    messages.remove(at: index)
    sequences.remove(at: index)
    sources[id] = nil
    normalizedIDs.remove(id.lowercased())
  }

  private static func transcriptMessage(_ message: ServerBotMessage) -> TranscriptBotMessage {
    TranscriptBotMessage(
      id: message.id,
      sender: sender(message.sender),
      text: message.text,
      attachments: (message.attachments ?? []).map(\.attachment),
      sentAt: ServerTimestamp.date(from: message.createdAt)
    )
  }

  private static func sender(_ sender: ServerBotMessageSender) -> TranscriptBotMessage.Sender {
    switch sender {
    case .user: .user
    case .bot: .bot
    case .notice: .notice
    }
  }
}

import Foundation

struct UnsentBotMessage: Equatable {
  var message: TranscriptBotMessage
  let afterSequence: Int?
}

enum BotConversationTimeline {
  static func messages(delivered log: BotMessageLog, unsent: [UnsentBotMessage]) -> [TranscriptBotMessage] {
    guard !unsent.isEmpty else { return log.messages }

    let slots = Dictionary(grouping: unsent) { slot(of: $0, among: log.sequences) }
    var messages = (slots[0] ?? []).map(\.message)
    for (index, message) in log.messages.enumerated() {
      messages.append(message)
      messages += (slots[index + 1] ?? []).map(\.message)
    }
    return messages
  }

  static func merging(
    _ queued: [UnsentBotMessage], into unsent: [UnsentBotMessage], deliveredIDs: Set<String>
  ) -> [UnsentBotMessage] {
    var merged = unsent
    for entry in queued where !deliveredIDs.contains(key(entry)) {
      guard let index = merged.firstIndex(where: { key($0) == key(entry) }) else {
        merged.append(entry)
        continue
      }
      guard merged[index].message.delivery == nil, let delivery = entry.message.delivery else { continue }
      merged[index].message = delivering(delivery, merged[index].message)
    }
    return merged
  }

  private static func slot(of entry: UnsentBotMessage, among sequences: [Int]) -> Int {
    guard let anchor = entry.afterSequence else { return sequences.count }

    var low = 0
    var high = sequences.count
    while low < high {
      let middle = (low + high) / 2
      if sequences[middle] <= anchor { low = middle + 1 } else { high = middle }
    }
    return low
  }

  private static func delivering(
    _ delivery: TranscriptDelivery, _ shown: TranscriptBotMessage
  ) -> TranscriptBotMessage {
    TranscriptBotMessage(
      id: shown.id, sender: shown.sender, text: shown.text, attachments: shown.attachments, sentAt: shown.sentAt,
      delivery: delivery)
  }

  private static func key(_ entry: UnsentBotMessage) -> String {
    entry.message.id.lowercased()
  }
}

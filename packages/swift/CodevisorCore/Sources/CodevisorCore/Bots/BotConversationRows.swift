import Foundation

public enum BotMessageDelivery: Equatable, Sendable {
  case delivered
  case sending
  case failed
}

public struct BotConversationEntry: Identifiable, Equatable, Sendable {
  public let message: ServerBotMessage
  public var delivery: BotMessageDelivery
  public var startsGroup: Bool
  public var endsGroup: Bool

  public var id: String { message.id }
  public var sender: ServerBotMessageSender { message.sender }
}

public enum BotConversationRow: Identifiable, Equatable, Sendable {
  case timestamp(Date)
  case message(BotConversationEntry)
  case notice(BotConversationEntry)

  public var id: String {
    switch self {
    case let .timestamp(date): "timestamp:\(date.timeIntervalSince1970)"
    case let .message(entry), let .notice(entry): entry.id
    }
  }
}

public enum BotConversationLayout {
  public static let timestampGap: TimeInterval = 15 * 60
  public static let groupGap: TimeInterval = 5 * 60

  public static func rows(
    _ messages: [(message: ServerBotMessage, delivery: BotMessageDelivery)]
  ) -> [BotConversationRow] {
    var rows: [BotConversationRow] = []
    var previousDate: Date?
    var entries: [BotConversationEntry] = []
    var dates: [Date?] = []
    for (message, delivery) in messages {
      let date = parseDate(message.createdAt)
      if let date, previousDate.map({ date.timeIntervalSince($0) > timestampGap }) ?? true {
        flush(&entries, into: &rows)
        rows.append(.timestamp(date))
        dates.removeAll()
      }
      let joinsPrevious: Bool = {
        guard message.sender != .notice, let last = entries.last, last.sender == message.sender else {
          return false
        }
        guard let previous = dates.last ?? nil, let date else { return true }
        return date.timeIntervalSince(previous) <= groupGap
      }()
      if !joinsPrevious {
        flush(&entries, into: &rows)
        dates.removeAll()
      }
      entries.append(
        BotConversationEntry(message: message, delivery: delivery, startsGroup: !joinsPrevious, endsGroup: true)
      )
      dates.append(date)
      if let date { previousDate = date }
    }
    flush(&entries, into: &rows)
    return rows
  }

  private static func flush(_ entries: inout [BotConversationEntry], into rows: inout [BotConversationRow]) {
    for index in entries.indices {
      var entry = entries[index]
      entry.endsGroup = index == entries.index(before: entries.endIndex)
      rows.append(entry.sender == .notice ? .notice(entry) : .message(entry))
    }
    entries.removeAll()
  }

  public static func parseDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
  }

  public static func timestamp(_ date: Date) -> String {
    ISO8601DateFormatter.string(
      from: date, timeZone: TimeZone(identifier: "UTC") ?? .current,
      formatOptions: [.withInternetDateTime, .withFractionalSeconds]
    )
  }
}

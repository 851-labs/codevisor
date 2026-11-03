import Foundation

public struct TranscriptQuote: Identifiable, Hashable, Sendable {
  public enum Role: String, Hashable, Sendable {
    case user
    case assistant
  }

  public let id: String
  public var text: String
  public var messageID: String
  public var role: Role
  public var sentAt: Date?

  public init(id: String = UUID().uuidString, text: String, messageID: String, role: Role, sentAt: Date? = nil) {
    self.id = id
    self.text = text
    self.messageID = messageID
    self.role = role
    self.sentAt = sentAt
  }

  public init?(text: String, row: TranscriptPresentationRow) {
    guard let messageID = Self.messageID(forRowKey: row.layoutKey) else { return nil }
    self.init(text: text, messageID: messageID, role: Self.role(of: row.content), sentAt: Self.sentAt(of: row.content))
  }

  public var snippet: String {
    let words = text.split(whereSeparator: \.isWhitespace)
    let collapsed = words.joined(separator: " ")
    guard collapsed.count > Self.snippetLength else { return collapsed }
    return collapsed.prefix(Self.snippetLength).trimmingCharacters(in: .whitespaces) + "…"
  }

  public func isSource(ofRowKey rowKey: String) -> Bool {
    Self.messageID(forRowKey: rowKey) == messageID
  }

  public static func sendFlightID(at index: Int) -> String {
    "quote-\(index)"
  }

  public static func messageID(forRowKey rowKey: String) -> String? {
    if rowKey.hasPrefix(botRowPrefix) { return String(rowKey.dropFirst(botRowPrefix.count)) }
    guard rowKey.hasPrefix(messageRowPrefix) else { return nil }
    let id = rowKey.dropFirst(messageRowPrefix.count).prefix { $0 != ":" }
    return id.isEmpty ? nil : String(id)
  }

  private static func role(of content: TranscriptPresentationRow.Content) -> Role {
    switch content {
    case .message(.user, _), .optimistic: .user
    case let .botMessage(message, _, _) where message.sender == .user: .user
    default: .assistant
    }
  }

  private static func sentAt(of content: TranscriptPresentationRow.Content) -> Date? {
    guard case let .botMessage(message, _, _) = content else { return nil }
    return message.sentAt
  }

  private static let snippetLength = 80
  private static let messageRowPrefix = "message:"
  private static let botRowPrefix = "bot:"
}

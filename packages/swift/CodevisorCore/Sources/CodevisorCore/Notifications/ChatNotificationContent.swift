import CodevisorProtocol
import Foundation

public struct ChatNotificationContent: Equatable, Sendable {
  public let title: String
  public let body: String

  public init(_ event: ChatAttentionEvent) {
    let chatName = event.sessionTitle.isEmpty ? "Chat" : event.sessionTitle
    guard let message = event.botMessage else {
      title = event.kind.notificationTitle
      body = chatName
      return
    }
    title = chatName
    body = Self.body(of: message)
  }

  private static func body(of message: BotMessagePreview) -> String {
    let lines = [message.text, attachmentLine(message.attachmentNames)]
    return lines.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  private static func attachmentLine(_ names: [String]) -> String? {
    guard !names.isEmpty else { return nil }
    return "📎 " + names.joined(separator: ", ")
  }
}

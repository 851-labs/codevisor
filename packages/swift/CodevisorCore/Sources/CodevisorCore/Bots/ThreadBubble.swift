import Foundation

public struct ThreadBubble: Identifiable, Equatable, Sendable {
  public let message: ServerThreadMessage
  public let showsName: Bool
  public let showsAvatar: Bool

  public var id: String { message.id }

  public static func rows(for messages: [ServerThreadMessage]) -> [ThreadBubble] {
    messages.indices.map { index in
      let message = messages[index]
      let previous = index > 0 ? messages[index - 1] : nil
      let next = index + 1 < messages.count ? messages[index + 1] : nil
      return ThreadBubble(
        message: message,
        showsName: previous?.from != message.from,
        showsAvatar: next?.from != message.from
      )
    }
  }
}

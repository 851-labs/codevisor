import CodevisorProtocol
import Foundation

public enum ChatAttentionKind: String, Sendable, CaseIterable {
  case finished
  case actionRequired

  public var notificationTitle: String {
    switch self {
    case .finished: "Chat finished"
    case .actionRequired: "Action required"
    }
  }
}

public struct ChatAttentionEvent: Sendable {
  public let id: UUID
  public let sessionId: UUID
  public let serverId: String
  public let sessionTitle: String
  public let kind: ChatAttentionKind
  public let botMessage: BotMessagePreview?

  public init(
    id: UUID = UUID(),
    sessionId: UUID,
    serverId: String,
    sessionTitle: String,
    kind: ChatAttentionKind,
    botMessage: BotMessagePreview? = nil
  ) {
    self.id = id
    self.sessionId = sessionId
    self.serverId = serverId
    self.sessionTitle = sessionTitle
    self.kind = kind
    self.botMessage = botMessage
  }
}

@MainActor
public protocol ChatNotificationDelivering: AnyObject {
  func deliver(_ event: ChatAttentionEvent)
  func clearNotifications(for sessionId: UUID)
  func prepareAuthorizationIfNeeded() async
}

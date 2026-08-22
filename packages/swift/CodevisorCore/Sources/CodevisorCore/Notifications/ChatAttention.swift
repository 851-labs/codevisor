import Foundation

/// Why a chat needs the user's attention. Shared so `SessionController` (and
/// each platform's notification manager) agree on the vocabulary; the actual
/// delivery mechanics (UNUserNotificationCenter, sounds, app activation) are
/// platform-owned.
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

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        serverId: String,
        sessionTitle: String,
        kind: ChatAttentionKind
    ) {
        self.id = id
        self.sessionId = sessionId
        self.serverId = serverId
        self.sessionTitle = sessionTitle
        self.kind = kind
    }
}

/// Platform notification delivery, driven by `SessionAttentionCoordinator`.
/// The macOS implementation is `ChatNotificationManager` (AppKit sounds + app
/// activation); iOS has none. The coordinator never delivers for the focused
/// chat, so implementations only decide banner-vs-sound presentation.
@MainActor
public protocol ChatNotificationDelivering: AnyObject {
    func deliver(_ event: ChatAttentionEvent)
    func clearNotifications(for sessionId: UUID)
    /// Requests notification authorization the first time it becomes useful
    /// (a turn just started that may finish while the user is elsewhere).
    func prepareAuthorizationIfNeeded() async
}

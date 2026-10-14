import CodevisorProtocol
import Foundation

public struct SessionAttentionSummary: Equatable, Sendable {
  public let sidebarState: SessionSidebarState
  public let latestAttentionSequence: Int
  public let lastSeenAttentionSequence: Int
  public let unreadCount: Int
  public let hasUnreadError: Bool
  public let actionRequired: Bool
  public let pendingPlanApproval: Bool
  public let title: String

  public init(_ session: ChatSession) {
    sidebarState = session.sidebarState
    latestAttentionSequence = session.latestAttentionSequence
    lastSeenAttentionSequence = session.lastSeenAttentionSequence
    unreadCount = session.unreadCount
    hasUnreadError = session.hasUnreadError
    actionRequired = session.actionRequired
    pendingPlanApproval = session.pendingPlanApproval
    title = session.title
  }

  public var hasUnseenAttention: Bool {
    unreadCount > 0 || hasUnreadError
      || latestAttentionSequence > lastSeenAttentionSequence
  }
}

public struct SessionAttentionTransition: Sendable {
  public enum Origin: Sendable, Equatable {
    case liveEvent
    case snapshot
    case localMarkRead
    case localMarkUnread
  }

  public let sessionId: UUID
  public let serverId: String
  public let old: SessionAttentionSummary?
  public let new: SessionAttentionSummary
  public let origin: Origin

  public init(
    sessionId: UUID,
    serverId: String,
    old: SessionAttentionSummary?,
    new: SessionAttentionSummary,
    origin: Origin
  ) {
    self.sessionId = sessionId
    self.serverId = serverId
    self.old = old
    self.new = new
    self.origin = origin
  }

  public static func notificationEdge(
    old: SessionAttentionSummary?,
    new: SessionAttentionSummary
  ) -> ChatAttentionKind? {
    guard let old else { return nil }
    if (new.actionRequired && !old.actionRequired)
      || (new.hasUnreadError && !old.hasUnreadError)
    {
      return .actionRequired
    }
    if new.unreadCount > 0, old.unreadCount == 0,
      new.latestAttentionSequence > old.latestAttentionSequence
    {
      return .finished
    }
    return nil
  }

  public var clearsDeliveredNotifications: Bool {
    guard let old else { return false }
    let wasNoteworthy = old.unreadCount > 0 || old.hasUnreadError || old.actionRequired
    let isQuiet = new.unreadCount == 0 && !new.hasUnreadError && !new.actionRequired
    return wasNoteworthy && isQuiet
  }
}

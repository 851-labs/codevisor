import CodevisorProtocol
import Foundation

/// The attention-relevant slice of one session summary. Transitions between
/// two of these drive everything the client does about attention: focus
/// auto-read, edge-triggered notifications, and banner clearing.
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

    /// Anything unseen: the focused chat reads this away immediately.
    public var hasUnseenAttention: Bool {
        unreadCount > 0 || hasUnreadError
            || latestAttentionSequence > lastSeenAttentionSequence
    }
}

/// One observed change of a session's attention state, emitted by
/// `ProjectListModel` from every path that mutates it. The coordinator turns
/// these into reads, pings, and banner clears — state transitions are the
/// single vocabulary, so notifications are edge-triggered by construction.
public struct SessionAttentionTransition: Sendable {
    /// Where the change came from. Only `liveEvent` transitions may ping:
    /// snapshot merges (app launch, reconnect catch-up) and our own local
    /// mutations must never sound like fresh activity.
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

    /// The single notification decision: a ping fires only on the transition
    /// INTO unread or action-required, never while the state persists.
    ///
    /// - Action-required (question, plan approval) and errors outrank
    ///   finished; both are urgent.
    /// - The `latestAttentionSequence`-increased guard on finished is what
    ///   makes a manual mark-unread (revision unchanged) never self-ping.
    /// - `old == nil` is a first sighting, not an edge.
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

    /// Whether this transition retires whatever banner the session may have:
    /// it was read (here, on another device, or by focus), or its blocking
    /// action was resolved.
    public var clearsDeliveredNotifications: Bool {
        guard let old else { return false }
        let wasNoteworthy = old.unreadCount > 0 || old.hasUnreadError || old.actionRequired
        let isQuiet = new.unreadCount == 0 && !new.hasUnreadError && !new.actionRequired
        return wasNoteworthy && isQuiet
    }
}

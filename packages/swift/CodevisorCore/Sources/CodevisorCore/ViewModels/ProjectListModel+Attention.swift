import Foundation

extension ProjectListModel {
  /// Shares read state through the server. The request carries the exact
  /// sequence this client saw, so a delayed request can't consume attention
  /// created after it was sent.
  @discardableResult
  public func markSessionRead(
    _ sessionId: UUID,
    serverId: String,
    throughSequence: Int? = nil
  ) -> Task<Void, Never>? {
    guard let before = session(sessionId, serverId: serverId) else { return nil }
    let rendered = min(
      max(0, throughSequence ?? before.latestAttentionSequence), before.latestAttentionSequence)
    // Focus-read fires continuously while a chat stays focused; repeated
    // triggers with nothing unseen must not spam the server.
    guard before.unreadCount > 0 || before.hasUnreadError || rendered > before.lastSeenAttentionSequence
    else { return nil }
    enqueue(
      .markSessionRead(sessionId: sessionId, throughSequence: rendered), serverId: serverId, origin: .localMarkRead)
    return nil
  }

  @discardableResult
  public func markSessionUnread(_ sessionId: UUID, serverId: String) -> Task<Void, Never>? {
    guard session(sessionId, serverId: serverId) != nil else { return nil }
    enqueue(.markSessionUnread(sessionId: sessionId), serverId: serverId, origin: .localMarkUnread)
    return nil
  }

  /// A visible transcript received and presented a terminal turn event, but
  /// the independent navigation stream may not have delivered the matching
  /// attention summary yet. `throughSequence` is captured when that visible
  /// turn starts, so it names exactly the completion the user saw. The server
  /// clamps the request to its current tip, meaning a parked finish is not
  /// read early, while a later autonomous turn can never be consumed by a
  /// delayed request.
  public func acknowledgePresentedTurnEnd(_ sessionId: UUID, serverId: String, throughSequence: Int) {
    guard let session = session(sessionId, serverId: serverId),
      session.lastSeenAttentionSequence < throughSequence
    else { return }
    enqueue(
      .markSessionRead(sessionId: sessionId, throughSequence: throughSequence), serverId: serverId,
      origin: .localMarkRead)
  }

  func emitAttentionTransition(
    old: ChatSession?,
    new: ChatSession,
    origin: SessionAttentionTransition.Origin
  ) {
    let oldSummary = old.map(SessionAttentionSummary.init)
    let newSummary = SessionAttentionSummary(new)
    guard oldSummary != newSummary else { return }
    onAttentionTransition?(
      SessionAttentionTransition(
        sessionId: new.id,
        serverId: new.serverId,
        old: oldSummary,
        new: newSummary,
        origin: origin
      ))
  }

  func emitAttentionTransitions(
    from previous: [ChatSession],
    to next: [ChatSession],
    origin: SessionAttentionTransition.Origin
  ) {
    for session in next {
      let old = previous.first { $0.serverId == session.serverId && $0.id == session.id }
      emitAttentionTransition(old: old, new: session, origin: origin)
    }
  }
}

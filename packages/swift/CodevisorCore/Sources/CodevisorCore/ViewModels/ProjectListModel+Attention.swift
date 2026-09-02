import Foundation

extension ProjectListModel {
    /// Shares read state through the server. The network request always carries
    /// the exact revision this client saw, so a delayed request cannot consume
    /// attention created after it was sent.
    public func markSessionRead(
        _ sessionId: UUID,
        serverId: String,
        throughSequence: Int? = nil
    ) {
        guard
            let index = sessions.firstIndex(where: {
                $0.serverId == serverId && $0.id == sessionId
            })
        else { return }
        let before = sessions[index]
        let rendered = min(
            max(0, throughSequence ?? before.latestAttentionSequence),
            before.latestAttentionSequence
        )
        // Focus-read fires continuously while a chat stays focused; repeated
        // triggers with nothing unseen must not spam the server.
        guard
            before.unreadCount > 0 || before.hasUnreadError
                || rendered > before.lastSeenAttentionSequence
        else { return }
        sessions[index].lastSeenAttentionSequence = max(
            sessions[index].lastSeenAttentionSequence,
            rendered
        )
        sessions[index].unreadCount = max(
            0,
            sessions[index].latestAttentionSequence - sessions[index].lastSeenAttentionSequence
        )
        if sessions[index].unreadCount == 0 {
            sessions[index].hasUnreadError = false
            if sessions[index].actionRequired {
                sessions[index].sidebarState = .waitingForUser
            } else if sessions[index].sidebarState != .inProgress {
                sessions[index].sidebarState = .idle
            }
        }
        persistSessions()
        emitAttentionTransition(old: before, new: sessions[index], origin: .localMarkRead)
        guard let serverClient = clientForServer(serverId) else { return }
        Task {
            do {
                if let remote = try await serverClient.markSessionRead(
                    id: sessionId,
                    throughSequence: rendered
                ) {
                    applyAttention(remote, serverId: serverId)
                }
            } catch {
                Log.sync.error(
                    "Failed to mark session \(sessionId.uuidString, privacy: .public) read: \(String(describing: error), privacy: .public)"
                )
                _ = await refreshFromServer(serverId: serverId, client: serverClient)
            }
        }
    }

    public func markSessionUnread(_ sessionId: UUID, serverId: String) {
        guard
            let index = sessions.firstIndex(where: {
                $0.serverId == serverId && $0.id == sessionId
            })
        else { return }
        let before = sessions[index]
        sessions[index].unreadCount = max(1, sessions[index].unreadCount)
        if sessions[index].sidebarState == .idle {
            sessions[index].sidebarState = .unread
        }
        persistSessions()
        emitAttentionTransition(old: before, new: sessions[index], origin: .localMarkUnread)
        guard let serverClient = clientForServer(serverId) else { return }
        Task {
            do {
                if let remote = try await serverClient.markSessionUnread(id: sessionId) {
                    applyAttention(remote, serverId: serverId)
                }
            } catch {
                Log.sync.error(
                    "Failed to mark session \(sessionId.uuidString, privacy: .public) unread: \(String(describing: error), privacy: .public)"
                )
                _ = await refreshFromServer(serverId: serverId, client: serverClient)
            }
        }
    }

    func applyAttention(_ remote: ServerSession, serverId: String) {
        guard let mapped = try? remote.chatSession(serverId: serverId),
            let id = UUID(uuidString: remote.id),
            let index = sessions.firstIndex(where: {
                $0.serverId == serverId && $0.id == id
            })
        else { return }
        guard !attentionIsNewer(sessions[index], than: mapped) else { return }
        let before = sessions[index]
        copyAttention(from: mapped, to: &sessions[index])
        persistSessions()
        emitAttentionTransition(old: before, new: sessions[index], origin: .snapshot)
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

    func attentionIsNewer(_ lhs: ChatSession, than rhs: ChatSession) -> Bool {
        if lhs.latestAttentionSequence != rhs.latestAttentionSequence {
            return lhs.latestAttentionSequence > rhs.latestAttentionSequence
        }
        if lhs.lastSeenAttentionSequence != rhs.lastSeenAttentionSequence {
            return lhs.lastSeenAttentionSequence > rhs.lastSeenAttentionSequence
        }
        return lhs.sidebarStateChangedAt > rhs.sidebarStateChangedAt
    }

    func copyAttention(from source: ChatSession, to destination: inout ChatSession) {
        destination.sidebarState = source.sidebarState
        destination.sidebarStateChangedAt = source.sidebarStateChangedAt
        destination.latestAttentionSequence = source.latestAttentionSequence
        destination.lastSeenAttentionSequence = source.lastSeenAttentionSequence
        destination.unreadCount = source.unreadCount
        destination.hasUnreadError = source.hasUnreadError
        destination.actionRequired = source.actionRequired
        destination.actionRequiredKind = source.actionRequiredKind
        destination.pendingPlanApproval = source.pendingPlanApproval
    }
}

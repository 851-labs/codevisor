import Foundation

extension ProjectListModel {
    /// Active sessions belonging to a project, newest first. Imported sessions
    /// are hidden unless `showsImportedSessions` is on.
    public func sessions(in project: Project) -> [ChatSession] {
        sessions
            .filter { session in
                session.projectId == project.id
                    && session.serverId == selectedServerId
                    && !session.isArchived
                    && (session.origin == .codevisor || showsImportedSessions)
            }
            .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
    }

    /// True if a project has any visible session (after import gating).
    public func hasVisibleSessions(in project: Project) -> Bool {
        !sessions(in: project).isEmpty
    }

    /// Archives a session, removing it from the active list without deleting it.
    public func archiveSession(_ session: ChatSession) {
        guard
            let index = sessions.firstIndex(where: {
                $0.serverId == session.serverId && $0.id == session.id
            })
        else { return }
        if clientForServer(session.serverId) != nil {
            pendingArchivedSessionIds.insert(
                ScopedSessionID(serverId: session.serverId, id: session.id)
            )
        }
        sessions[index].isArchived = true
        // Stamped locally so the row lands at the top of the archived list
        // immediately, instead of waiting for the server's own timestamp to
        // arrive on the next refresh. The server value overwrites this on
        // merge; the two differ only by the round-trip.
        sessions[index].archivedAt = Date()
        persistSessions()
        syncSession(sessions[index])
    }

    /// Restores an archived session to the active list.
    ///
    /// Clearing the pending marker is mandatory, not tidiness: `mergeSessions`
    /// forces `isArchived = true` on any remote row still listed there, so a
    /// leftover marker would pin the chat archived forever — it would pop back
    /// out of the sidebar on the very next server refresh.
    public func unarchiveSession(_ session: ChatSession) {
        guard
            let index = sessions.firstIndex(where: {
                $0.serverId == session.serverId && $0.id == session.id
            })
        else { return }
        pendingArchivedSessionIds.remove(
            ScopedSessionID(serverId: session.serverId, id: session.id)
        )
        sessions[index].isArchived = false
        sessions[index].archivedAt = nil
        persistSessions()
        syncSession(sessions[index])
    }

    /// Archived chats belonging to a project, newest archive first.
    public func archivedSessions(in project: Project) -> [ChatSession] {
        sessions
            .filter { session in
                session.projectId == project.id
                    && session.serverId == selectedServerId
                    && session.isArchived
                    && (session.origin == .codevisor || showsImportedSessions)
            }
            .sorted(by: Self.archivedOrdering)
    }

    /// Every archived chat on the selected machine, newest archive first.
    ///
    /// Deliberately not derived from `activeProjects`: that list drops an
    /// imported project once its last active chat is archived, which would
    /// make the chat the user just archived disappear from the archive too.
    public var archivedSessions: [ChatSession] {
        sessions
            .filter { session in
                session.serverId == selectedServerId
                    && session.isArchived
                    && (session.origin == .codevisor || showsImportedSessions)
            }
            .sorted(by: Self.archivedOrdering)
    }

    /// Orders by archive recency, falling back to activity for rows archived
    /// before `archivedAt` existed so they sort last rather than first.
    private static func archivedOrdering(_ left: ChatSession, _ right: ChatSession) -> Bool {
        let leftStamp = left.archivedAt ?? left.updatedAt ?? left.createdAt
        let rightStamp = right.archivedAt ?? right.updatedAt ?? right.createdAt
        return leftStamp > rightStamp
    }
}

import Foundation

extension ProjectListModel {
    /// Shared: formatter construction is milliseconds-expensive and the
    /// import loops used to build one per imported session. Native scanners
    /// emit JavaScript ISO strings with fractional seconds; legacy servers may
    /// still return whole-second timestamps, so accept both forms.
    private static let fractionalImportTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeSecondImportTimestampFormatter = ISO8601DateFormatter()

    /// Imports sessions discovered from harnesses, creating projects by cwd and
    /// skipping any already known (by harness + agent session id).
    ///
    /// `serverId` is the machine the sessions were discovered on, snapshotted
    /// by the caller BEFORE the async discovery ran. Discovery is a network
    /// round-trip; tagging results with the live `selectedServerId` here would
    /// file another machine's sessions (and their projects) under whichever
    /// machine the user has switched to meanwhile.
    public func importSessions(_ imported: [ImportedSession], serverId: String) {
        for item in imported {
            if let knownIndex = sessions.firstIndex(where: {
                $0.serverId == serverId
                    && $0.harnessId == item.harnessId
                    && $0.agentSessionId == item.info.sessionId
            }) {
                reconcileImportedActivity(item, at: knownIndex)
                continue
            }
            let project = findOrCreateProject(
                folderURL: URL(fileURLWithPath: item.info.cwd),
                serverId: serverId
            )
            let timestamp = Self.importTimestamp(item.info.updatedAt)
            sessions.append(
                ChatSession(
                    projectId: project.id,
                    serverId: serverId,
                    harnessId: item.harnessId,
                    agentSessionId: item.info.sessionId,
                    title: item.info.title ?? "Session",
                    origin: .imported,
                    createdAt: timestamp ?? Date(),
                    updatedAt: timestamp
                ))
        }
        persistProjects()
        persistSessions()
        syncAllToServer(serverId: serverId)
    }

    /// Imports sessions into a specific project (they were discovered for its
    /// folder), merging newer activity into known harness-session records.
    /// Sessions inherit the project's server, not the currently selected one:
    /// the user may confirm a pending import after switching machines.
    public func importSessions(_ imported: [ImportedSession], into project: Project) {
        var didChange = false
        for item in imported {
            if let knownIndex = sessions.firstIndex(where: {
                $0.serverId == project.serverId
                    && $0.harnessId == item.harnessId
                    && $0.agentSessionId == item.info.sessionId
            }) {
                didChange = reconcileImportedActivity(item, at: knownIndex) || didChange
                continue
            }
            let timestamp = Self.importTimestamp(item.info.updatedAt)
            sessions.append(
                ChatSession(
                    projectId: project.id,
                    serverId: project.serverId,
                    harnessId: item.harnessId,
                    agentSessionId: item.info.sessionId,
                    title: item.info.title ?? "Session",
                    origin: .imported,
                    createdAt: timestamp ?? Date(),
                    updatedAt: timestamp
                ))
            didChange = true
        }
        guard didChange else { return }
        persistSessions()
        syncAllToServer(serverId: project.serverId)
    }

    /// Native-session discovery is also our source of truth for activity that
    /// happened outside this app. Never roll a cached/server timestamp back,
    /// and leave user-edited metadata (especially the title) alone.
    @discardableResult
    private func reconcileImportedActivity(_ item: ImportedSession, at index: Int) -> Bool {
        guard let discoveredAt = Self.importTimestamp(item.info.updatedAt) else {
            return false
        }
        let cachedAt = sessions[index].updatedAt ?? sessions[index].createdAt
        guard discoveredAt > cachedAt else { return false }
        sessions[index].updatedAt = discoveredAt
        return true
    }

    private static func importTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractionalImportTimestampFormatter.date(from: value)
            ?? wholeSecondImportTimestampFormatter.date(from: value)
    }

    /// Finds a project by folder, or creates one (without changing archive
    /// state). Used by the importer so it doesn't un-archive existing folders.
    private func findOrCreateProject(folderURL: URL, serverId: String) -> Project {
        if let existing = projects.first(where: { $0.serverId == serverId && $0.folderURL == folderURL }) {
            return existing
        }
        let project = Project.fromFolder(folderURL, serverId: serverId, origin: .imported)
        projects.append(project)
        return project
    }
}

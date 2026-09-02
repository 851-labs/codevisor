import Foundation

extension ProjectListModel {
    /// Projects shown in the main section: user-added ones always appear;
    /// imported ones only when they have a visible session.
    public var activeProjects: [Project] {
        projects
            .filter {
                $0.serverId == selectedServerId
                    && !$0.isArchived
                    && ($0.origin == .codevisor || hasVisibleSessions(in: $0))
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Orders active projects by the most recent workspace created for each
    /// one. Projects without workspace history retain their normal
    /// newest-project-first order after projects that have been used.
    public func activeProjectsByWorkspaceRecency(
        _ workspaces: [Workspace]
    ) -> [Project] {
        var latestWorkspaceDates: [UUID: Date] = [:]
        for workspace in workspaces where workspace.serverId == selectedServerId {
            latestWorkspaceDates[workspace.projectId] = max(
                latestWorkspaceDates[workspace.projectId] ?? .distantPast,
                workspace.createdAt
            )
        }

        return activeProjects.enumerated().sorted { left, right in
            switch (
                latestWorkspaceDates[left.element.id],
                latestWorkspaceDates[right.element.id]
            ) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return left.offset < right.offset
            }
        }
        .map(\.element)
    }

    /// Projects in the archived section.
    public var archivedProjects: [Project] {
        projects
            .filter { $0.serverId == selectedServerId && $0.isArchived }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Adds a project for a folder, reusing an existing entry if the folder
    /// is already present (un-archiving it if needed).
    @discardableResult
    public func addProject(folderURL: URL) -> Project {
        addProject(folderURL: folderURL, serverId: selectedServerId)
    }

    /// Adds a project for an explicit machine. App flows use this entry point
    /// so a composer default cannot redirect persistence or server writes.
    @discardableResult
    public func addProject(folderURL: URL, serverId: String) -> Project {
        if let index = projects.firstIndex(where: { $0.serverId == serverId && $0.folderURL == folderURL }) {
            projects[index].isArchived = false
            persistProjects()
            syncProject(projects[index])
            return projects[index]
        }
        let project = Project.fromFolder(folderURL, serverId: serverId)
        projects.append(project)
        persistProjects()
        syncProject(project)
        return project
    }

    /// Registers a project the selected server already owns (a fresh
    /// clone-from-git) under the server's project id, so the local list and
    /// the server describe one project instead of merging by folder later.
    @discardableResult
    public func adoptServerProject(
        id: UUID, folderURL: URL, name: String, serverId: String? = nil
    ) -> Project {
        let server = serverId ?? selectedServerId
        pendingServerProjectIds.remove(
            ScopedSessionID(serverId: server, id: id)
        )
        if let index = projects.firstIndex(where: { $0.serverId == server && $0.id == id }) {
            projects[index].isArchived = false
            persistProjects()
            return projects[index]
        }
        var project = Project.fromFolder(folderURL, serverId: server)
        project.id = id
        project.name = name
        project.locations = project.locations.map { location in
            var updated = location
            updated.projectId = id
            return updated
        }
        projects.append(project)
        persistProjects()
        return project
    }

    public func archive(_ project: Project) {
        setArchived(true, for: project)
    }

    public func unarchive(_ project: Project) {
        setArchived(false, for: project)
    }

    public func removeProject(_ project: Project) {
        pendingServerProjectIds.remove(
            ScopedSessionID(serverId: project.serverId, id: project.id)
        )
        pendingDeletedProjectIds.insert(
            ScopedSessionID(serverId: project.serverId, id: project.id)
        )
        let removedSessionIDs =
            sessions
            .filter { $0.serverId == project.serverId && $0.projectId == project.id }
            .map(\.id)
        pendingServerSessionIds.subtract(
            removedSessionIDs.map {
                ScopedSessionID(serverId: project.serverId, id: $0)
            })
        pendingArchivedSessionIds.subtract(
            removedSessionIDs.map {
                ScopedSessionID(serverId: project.serverId, id: $0)
            })
        projects.removeAll { $0.serverId == project.serverId && $0.id == project.id }
        sessions.removeAll { $0.serverId == project.serverId && $0.projectId == project.id }
        persistProjects()
        persistSessions()
        deleteProjectFromServer(
            project.id,
            serverId: project.serverId,
            removedSessionIDs: removedSessionIDs
        )
    }

    private func setArchived(_ archived: Bool, for project: Project) {
        guard
            let index = projects.firstIndex(where: {
                $0.serverId == project.serverId && $0.id == project.id
            })
        else { return }
        projects[index].isArchived = archived
        persistProjects()
        syncProject(projects[index])
    }
}

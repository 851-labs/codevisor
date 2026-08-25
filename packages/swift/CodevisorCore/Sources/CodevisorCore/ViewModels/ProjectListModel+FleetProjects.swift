import Foundation

extension ProjectListModel {
    /// Adds a project on an EXPLICIT machine — the fleet-wide picker's "New
    /// Project…" flow, which may target a machine other than the selected
    /// one. Dedupe and un-archive semantics match `addProject(folderURL:)`;
    /// the upsert goes through the passed client so it reaches the right
    /// server.
    @discardableResult
    public func addProject(
        folderURL: URL,
        serverId: String,
        client: any CodevisorServerClienting
    ) -> Project {
        if let index = projects.firstIndex(where: {
            $0.serverId == serverId && $0.folderURL == folderURL
        }) {
            projects[index].isArchived = false
            persistProjects()
            syncProject(projects[index], via: client)
            return projects[index]
        }
        let project = Project.fromFolder(folderURL, serverId: serverId)
        projects.append(project)
        persistProjects()
        syncProject(project, via: client)
        return project
    }

    /// Pushes a project to ITS machine through the given client (the
    /// selected-machine `syncProject` guard doesn't apply here).
    private func syncProject(_ project: Project, via client: any CodevisorServerClienting) {
        pendingServerProjectIds.insert(
            ScopedSessionID(serverId: project.serverId, id: project.id)
        )
        Task {
            do {
                _ = try await client.upsertProject(project)
            } catch {
                Log.sync.error(
                    "Failed to sync project \(project.id.uuidString, privacy: .public) to the server: \(String(describing: error), privacy: .public)"
                )
                ErrorReporter.shared.report(
                    .projectSyncFailed,
                    title: "Couldn't Sync the Project to the Server",
                    error: error
                )
            }
        }
    }
}

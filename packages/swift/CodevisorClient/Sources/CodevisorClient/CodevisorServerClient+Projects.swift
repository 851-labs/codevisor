import ACPKit
import CodevisorProtocol
import Foundation

public struct ServerProjectLocation: Decodable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var serverId: String
    public var folderPath: String
    public var createdAt: String
    public var isGitRepository: Bool?

    public init(
        id: String,
        projectId: String,
        serverId: String,
        folderPath: String,
        createdAt: String,
        isGitRepository: Bool? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.serverId = serverId
        self.folderPath = folderPath
        self.createdAt = createdAt
        self.isGitRepository = isGitRepository
    }
}

public struct ServerFsEntry: Decodable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var isGitRepo: Bool

    public init(name: String, path: String, isGitRepo: Bool) {
        self.name = name
        self.path = path
        self.isGitRepo = isGitRepo
    }
}

public struct ServerFsListing: Decodable, Equatable, Sendable {
    public var path: String
    public var parent: String?
    public var entries: [ServerFsEntry]

    public init(path: String, parent: String?, entries: [ServerFsEntry]) {
        self.path = path
        self.parent = parent
        self.entries = entries
    }
}

public struct ServerProject: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isArchived: Bool
    public var origin: SessionOrigin
    public var createdAt: String
    public var locations: [ServerProjectLocation]
    public var worktreeBase: ProjectWorktreeBase? = nil
    /// The git remote this project was cloned from, for projects added via
    /// clone-from-git. Absent on older servers and directory-based projects.
    public var repoUrl: String? = nil
    /// True for the hidden backing project of a scratch workspace (folder
    /// under ~/codevisor/workspaces). Absent on older servers.
    public var isScratch: Bool? = nil

    public func project(serverId: String = "local") throws -> Project {
        guard let uuid = UUID(uuidString: id) else {
            throw CodevisorServerClientError.invalidUUID(id)
        }
        return Project(
            id: uuid,
            serverId: serverId,
            name: name,
            isArchived: isArchived,
            origin: origin,
            createdAt: try ServerDateCoding.date(from: createdAt),
            locations: locations.map { location in
                // Stamp the location with the client's machine id, not the
                // server's self-reported id (always "local"). Otherwise
                // `location(for: machineId)` misses on remote machines, so
                // `isGitRepository` (and the folder lookup) silently fall back
                // — which is why worktrees looked disabled on remote repos.
                ProjectLocation(
                    id: location.id,
                    projectId: uuid,
                    serverId: serverId,
                    folderPath: location.folderPath,
                    isGitRepository: location.isGitRepository
                )
            },
            worktreeBase: worktreeBase,
            isScratch: isScratch ?? false
        )
    }

    public init(
        id: String,
        name: String,
        isArchived: Bool,
        origin: SessionOrigin,
        createdAt: String,
        locations: [ServerProjectLocation],
        worktreeBase: ProjectWorktreeBase? = nil,
        repoUrl: String? = nil,
        isScratch: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.isArchived = isArchived
        self.origin = origin
        self.createdAt = createdAt
        self.locations = locations
        self.worktreeBase = worktreeBase
        self.repoUrl = repoUrl
        self.isScratch = isScratch
    }
}

/// Server-owned workspace identity and navigation metadata. Pane identity is
/// fetched separately; only each device's tab/split layout remains local.
public struct ServerWorkspace: Decodable, Equatable, Sendable {
    public var id: String
    public var serverId: String
    public var projectId: String
    public var name: String
    public var hasCustomName: Bool
    public var rootDirectory: String?
    public var isArchived: Bool
    public var archivedAt: String?
    public var createdAt: String
    public var updatedAt: String?

    public init(
        id: String,
        serverId: String,
        projectId: String,
        name: String,
        hasCustomName: Bool,
        rootDirectory: String? = nil,
        isArchived: Bool,
        archivedAt: String? = nil,
        createdAt: String,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.projectId = projectId
        self.name = name
        self.hasCustomName = hasCustomName
        self.rootDirectory = rootDirectory
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Server-owned pane identity. Native layout stores this id in a client-local
/// tab/split tree; provider/type/resource describe the renderer independently
/// of where a client chooses to place it.
public struct ServerWorkspacePane: Codable, Equatable, Sendable {
    public var id: String
    public var workspaceId: String
    public var providerId: String
    public var paneType: String
    public var title: String
    public var resourceKind: String?
    public var resourceId: String?
    public var metadata: String?
    /// Monotonic content revision. Nil only when talking to a server that
    /// predates revisioned pane snapshots.
    public var revision: Int?
    public var createdAt: String
    public var updatedAt: String?

    public init(
        id: String,
        workspaceId: String,
        providerId: String,
        paneType: String,
        title: String,
        resourceKind: String? = nil,
        resourceId: String? = nil,
        metadata: String? = nil,
        revision: Int? = nil,
        createdAt: String,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.providerId = providerId
        self.paneType = paneType
        self.title = title
        self.resourceKind = resourceKind
        self.resourceId = resourceId
        self.metadata = metadata
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Workspaces and their shared pane registry captured in one server read.
public struct ServerWorkspaceSnapshot: Decodable, Equatable, Sendable {
    public var workspaces: [ServerWorkspace]
    public var panes: [ServerWorkspacePane]

    public init(workspaces: [ServerWorkspace], panes: [ServerWorkspacePane]) {
        self.workspaces = workspaces
        self.panes = panes
    }
}

private struct ServerWorkspacePaneClose: Decodable {
    var pane: ServerWorkspacePane?
}

public struct ServerWorkspacePanePromotion: Decodable, Equatable, Sendable {
    public var pane: ServerWorkspacePane
    public var session: ServerSession

    public init(pane: ServerWorkspacePane, session: ServerSession) {
        self.pane = pane
        self.session = session
    }
}

private struct UpsertWorkspacePaneBody: Encodable {
    var id: String
    var providerId: String
    var paneType: String
    var title: String
    var resourceKind: String?
    var resourceId: String?
    var metadata: String?
    var createdAt: String

    init(_ pane: ServerWorkspacePane) {
        id = pane.id
        providerId = pane.providerId
        paneType = pane.paneType
        title = pane.title
        resourceKind = pane.resourceKind
        resourceId = pane.resourceId
        metadata = pane.metadata
        createdAt = pane.createdAt
    }
}

private struct PromoteWorkspacePaneToChatBody: Encodable {
    var session: CreateSessionBody
    var title: String

    init(pane: ServerWorkspacePane, session: ChatSession) {
        self.session = CreateSessionBody(session: session)
        title = pane.title
    }
}

public struct ServerWorktree: Decodable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var serverId: String
    public var name: String
    public var branch: String
    public var path: String
    public var createdAt: String
}

struct CreateProjectBody: Encodable {
    var id: String
    var folderPath: String
    var name: String
    var isArchived: Bool
    var origin: SessionOrigin
    var createdAt: String

    init(project: Project) {
        id = project.id.uuidString
        folderPath = project.folderURL.path
        name = project.name
        isArchived = project.isArchived
        origin = project.origin
        createdAt = ServerDateCoding.string(from: project.createdAt)
    }
}

private struct UpdateProjectBody: Encodable {
    var name: String
    var isArchived: Bool

    init(project: Project) {
        name = project.name
        isArchived = project.isArchived
    }
}

private struct CreateWorktreeBody: Encodable {
    var id: String?
    var name: String?
}

private struct CreateProjectFromGitBody: Encodable {
    var id: String
    var url: String
    var name: String?
}

private struct CreateScratchProjectBody: Encodable {
    var id: String
}

/// Moves a not-yet-started session to another project/worktree. Deliberately
/// its own body (not `UpdateSessionBody`): sending `projectId` makes the
/// server treat the PATCH as a directory move, which is refused once the
/// agent has started — routine updates must never carry it.
private struct MoveSessionBody: Encodable {
    var projectId: String
    var worktreeName: String?
}

private struct UpsertWorkspaceBody: Encodable {
    var id: String
    var projectId: String
    var name: String
    var hasCustomName: Bool
    var rootDirectory: String?
    var isArchived: Bool
    var createdAt: String

    init(_ workspace: ServerWorkspace) {
        id = workspace.id
        projectId = workspace.projectId
        name = workspace.name
        hasCustomName = workspace.hasCustomName
        rootDirectory = workspace.rootDirectory
        isArchived = workspace.isArchived
        createdAt = workspace.createdAt
    }
}

extension CodevisorServerClient {
    public func listProjects() async throws -> [ServerProject] {
        try await get("/v1/projects")
    }

    public func upsertProject(_ project: Project) async throws -> ServerProject {
        let remoteProjects = try await listProjects()
        // Compare as UUIDs: the server lowercases ids while Swift's
        // uuidString is uppercase — a string comparison never matches, which
        // sent every "update" down the create path (and archiving, whose
        // PATCH therefore never fired, silently reverted).
        if remoteProjects.contains(where: { UUID(uuidString: $0.id) == project.id }) {
            return try await updateProject(project)
        }
        return try await createProject(project)
    }

    public func updateProject(_ project: Project) async throws -> ServerProject {
        try await send(
            "/v1/projects/\(project.id.uuidString)",
            method: "PATCH",
            body: UpdateProjectBody(project: project)
        )
    }

    public func deleteProject(id: UUID) async throws {
        try await sendNoResponse("/v1/projects/\(id.uuidString)", method: "DELETE")
    }

    public func createScratchProject(id: UUID) async throws -> ServerProject {
        try await send(
            "/v1/projects/scratch",
            method: "POST",
            body: CreateScratchProjectBody(id: id.uuidString)
        )
    }

    public func moveSession(id: UUID, projectId: UUID, worktreeName: String?) async throws -> ServerSession {
        try await send(
            "/v1/sessions/\(id.uuidString)",
            method: "PATCH",
            body: MoveSessionBody(projectId: projectId.uuidString, worktreeName: worktreeName)
        )
    }

    public func listWorktrees(projectId: UUID) async throws -> [ServerWorktree] {
        try await get("/v1/projects/\(projectId.uuidString)/worktrees")
    }

    public func listWorkspaces() async throws -> [ServerWorkspace]? {
        do {
            return try await get("/v1/workspaces")
        } catch CodevisorServerClientError.httpStatus(404, _) {
            return nil
        } catch CodevisorServerClientError.httpStatus(405, _) {
            return nil
        }
    }

    public func workspaceSnapshot() async throws -> ServerWorkspaceSnapshot? {
        do {
            return try await get("/v1/workspace-snapshot")
        } catch CodevisorServerClientError.httpStatus(404, _) {
            return nil
        } catch CodevisorServerClientError.httpStatus(405, _) {
            return nil
        }
    }

    public func upsertWorkspace(_ workspace: ServerWorkspace) async throws -> ServerWorkspace? {
        do {
            return try await send(
                "/v1/workspaces/\(workspace.id)",
                method: "PUT",
                body: UpsertWorkspaceBody(workspace)
            )
        } catch CodevisorServerClientError.httpStatus(404, _) {
            return nil
        } catch CodevisorServerClientError.httpStatus(405, _) {
            return nil
        }
    }

    public func listWorkspacePanes() async throws -> [ServerWorkspacePane]? {
        do {
            return try await get("/v1/workspace-panes")
        } catch CodevisorServerClientError.httpStatus(404, _) {
            return nil
        } catch CodevisorServerClientError.httpStatus(405, _) {
            return nil
        }
    }

    public func upsertWorkspacePane(_ pane: ServerWorkspacePane) async throws -> ServerWorkspacePane? {
        do {
            return try await send(
                "/v1/workspaces/\(pane.workspaceId)/panes/\(pane.id)",
                method: "PUT",
                body: UpsertWorkspacePaneBody(pane)
            )
        } catch CodevisorServerClientError.httpStatus(404, _) {
            return nil
        } catch CodevisorServerClientError.httpStatus(405, _) {
            return nil
        }
    }

    public func promoteWorkspacePaneToChat(
        _ pane: ServerWorkspacePane,
        session: ChatSession
    ) async throws -> ServerWorkspacePanePromotion? {
        do {
            return try await send(
                "/v1/workspaces/\(pane.workspaceId)/panes/\(pane.id)/promote-chat",
                method: "POST",
                body: PromoteWorkspacePaneToChatBody(pane: pane, session: session)
            )
        } catch CodevisorServerClientError.httpStatus(404, _) {
            return nil
        } catch CodevisorServerClientError.httpStatus(405, _) {
            return nil
        }
    }

    public func deleteWorkspacePane(workspaceId: UUID, paneId: UUID) async throws {
        do {
            try await sendNoResponse(
                "/v1/workspaces/\(workspaceId.uuidString)/panes/\(paneId.uuidString)",
                method: "DELETE"
            )
        } catch CodevisorServerClientError.httpStatus(404, _) {
            return
        } catch CodevisorServerClientError.httpStatus(405, _) {
            return
        }
    }

    public func closeWorkspacePane(workspaceId: UUID, paneId: UUID) async throws -> ServerWorkspacePane? {
        do {
            let response: ServerWorkspacePaneClose = try await send(
                "/v1/workspaces/\(workspaceId.uuidString)/panes/\(paneId.uuidString)/close",
                method: "POST",
                body: Optional<EmptyBody>.none
            )
            return response.pane
        } catch CodevisorServerClientError.httpStatus(404, _) {
            try await deleteWorkspacePane(workspaceId: workspaceId, paneId: paneId)
            return nil
        } catch CodevisorServerClientError.httpStatus(405, _) {
            try await deleteWorkspacePane(workspaceId: workspaceId, paneId: paneId)
            return nil
        }
    }

    public func createWorktree(projectId: UUID, name: String?) async throws -> ServerWorktree {
        try await createWorktree(projectId: projectId, id: nil, name: name)
    }

    public func createWorktree(projectId: UUID, id: String?, name: String?) async throws -> ServerWorktree {
        try await send(
            "/v1/projects/\(projectId.uuidString)/worktrees",
            method: "POST",
            body: CreateWorktreeBody(id: id, name: name)
        )
    }

    private struct CreatedDirectory: Decodable {
        let path: String
    }

    /// Creates a folder on this machine (the remote browser's "New Folder").
    public func createDirectory(path: String) async throws -> String {
        struct Body: Encodable {
            let path: String
        }
        let created: CreatedDirectory = try await send(
            "/v1/fs/mkdir", method: "POST", body: Body(path: path)
        )
        return created.path
    }

    public func listDirectory(path: String?, showHidden: Bool) async throws -> ServerFsListing {
        var components = URLComponents()
        components.path = "/v1/fs/list"
        var query: [URLQueryItem] = []
        if let path {
            query.append(URLQueryItem(name: "path", value: path))
        }
        if showHidden {
            query.append(URLQueryItem(name: "showHidden", value: "true"))
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let requestPath = components.string else {
            throw CodevisorServerClientError.invalidURL("fs/list")
        }
        return try await get(requestPath)
    }

    public func createProjectFromGit(id: UUID, url: String, name: String?) async throws -> ServerProject {
        // Clones legitimately run for minutes on large repos; the default
        // request timeout would abort mid-transfer. Send the id in the same
        // (upper) case the client uses everywhere else — session creation
        // looks the project up by that exact string, so a lowercased id here
        // would store a project the client can never address ("not found").
        try await send(
            "/v1/projects/from-git",
            method: "POST",
            body: CreateProjectFromGitBody(id: id.uuidString, url: url, name: name),
            timeout: 1800
        )
    }

    private func createProject(_ project: Project) async throws -> ServerProject {
        try await send(
            "/v1/projects",
            method: "POST",
            body: CreateProjectBody(project: project)
        )
    }
}

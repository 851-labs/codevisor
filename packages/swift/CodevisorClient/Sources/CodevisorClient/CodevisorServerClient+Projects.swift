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
    public var symbolName: String
    public var origin: SessionOrigin
    public var createdAt: String
    public var locations: [ServerProjectLocation]
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
            symbolName: symbolName,
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
            isScratch: isScratch ?? false
        )
    }

    public init(
        id: String,
        name: String,
        isArchived: Bool,
        symbolName: String,
        origin: SessionOrigin,
        createdAt: String,
        locations: [ServerProjectLocation],
        repoUrl: String? = nil,
        isScratch: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.isArchived = isArchived
        self.symbolName = symbolName
        self.origin = origin
        self.createdAt = createdAt
        self.locations = locations
        self.repoUrl = repoUrl
        self.isScratch = isScratch
    }
}

/// Server-owned workspace identity and navigation metadata. Pane trees remain
/// device-local and are merged by `WorkspaceSyncModel`.
public struct ServerWorkspace: Decodable, Equatable, Sendable {
    public var id: String
    public var serverId: String
    public var projectId: String
    public var name: String
    public var hasCustomName: Bool
    public var symbolName: String?
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
        symbolName: String? = nil,
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
        self.symbolName = symbolName
        self.rootDirectory = rootDirectory
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
    var symbolName: String
    var origin: SessionOrigin
    var createdAt: String

    init(project: Project) {
        id = project.id.uuidString
        folderPath = project.folderURL.path
        name = project.name
        isArchived = project.isArchived
        symbolName = project.symbolName
        origin = project.origin
        createdAt = ServerDateCoding.string(from: project.createdAt)
    }
}

private struct UpdateProjectBody: Encodable {
    var name: String
    var isArchived: Bool
    var symbolName: String

    init(project: Project) {
        name = project.name
        isArchived = project.isArchived
        symbolName = project.symbolName
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

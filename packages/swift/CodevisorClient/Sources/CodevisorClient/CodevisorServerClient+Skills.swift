import ACPKit
import CodevisorProtocol
import Foundation

public struct ServerSkillHarnessInstall: Codable, Equatable, Sendable {
    public var harnessId: String
    /// linked | copied | canonical | notInstalled | broken | conflict
    public var state: String

    public init(harnessId: String, state: String) {
        self.harnessId = harnessId
        self.state = state
    }
}

/// A skill in the canonical ~/.agents/skills store with per-harness installs.
public struct ServerGlobalSkill: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var directoryName: String
    public var description: String?
    public var path: String
    public var invalid: Bool?
    public var installs: [ServerSkillHarnessInstall]

    public var id: String { directoryName }

    public init(
        name: String,
        directoryName: String,
        description: String? = nil,
        path: String,
        invalid: Bool? = nil,
        installs: [ServerSkillHarnessInstall] = []
    ) {
        self.name = name
        self.directoryName = directoryName
        self.description = description
        self.path = path
        self.invalid = invalid
        self.installs = installs
    }
}

/// A skill found in a harness's own skills directory that is not a link into
/// the canonical store: an independent copy or a broken link.
public struct ServerHarnessSkill: Codable, Equatable, Identifiable, Sendable {
    public var harnessId: String
    public var directoryName: String
    public var name: String
    public var description: String?
    public var path: String
    /// independent | broken
    public var classification: String
    public var invalid: Bool?
    public var duplicateOf: String?

    public var id: String { "\(harnessId)|\(directoryName)" }

    public init(
        harnessId: String,
        directoryName: String,
        name: String,
        description: String? = nil,
        path: String,
        classification: String,
        invalid: Bool? = nil,
        duplicateOf: String? = nil
    ) {
        self.harnessId = harnessId
        self.directoryName = directoryName
        self.name = name
        self.description = description
        self.path = path
        self.classification = classification
        self.invalid = invalid
        self.duplicateOf = duplicateOf
    }
}

public struct ServerSkillsHarnessGroup: Codable, Equatable, Identifiable, Sendable {
    public var harnessId: String
    public var harnessName: String
    /// SF Symbol from the harness catalog; nil from older servers.
    public var harnessSymbol: String?
    public var skillsDir: String
    public var skills: [ServerHarnessSkill]

    public var id: String { harnessId }

    public init(
        harnessId: String,
        harnessName: String,
        harnessSymbol: String? = nil,
        skillsDir: String,
        skills: [ServerHarnessSkill] = []
    ) {
        self.harnessId = harnessId
        self.harnessName = harnessName
        self.harnessSymbol = harnessSymbol
        self.skillsDir = skillsDir
        self.skills = skills
    }
}

/// One skill offered by a remote source, for the pre-import picker.
public struct ServerRemoteSkillCandidate: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var directoryName: String
    public var description: String?
    public var alreadyExists: Bool

    public var id: String { directoryName }

    public init(name: String, directoryName: String, description: String? = nil, alreadyExists: Bool = false) {
        self.name = name
        self.directoryName = directoryName
        self.description = description
        self.alreadyExists = alreadyExists
    }
}

public struct ServerSkillsScan: Codable, Equatable, Sendable {
    public var canonicalDir: String
    public var global: [ServerGlobalSkill]
    public var harnesses: [ServerSkillsHarnessGroup]

    public init(
        canonicalDir: String = "",
        global: [ServerGlobalSkill] = [],
        harnesses: [ServerSkillsHarnessGroup] = []
    ) {
        self.canonicalDir = canonicalDir
        self.global = global
        self.harnesses = harnesses
    }
}

extension CodevisorServerClient {
    public func listSkills() async throws -> ServerSkillsScan {
        try await get("/v1/skills")
    }

    private struct CreateSkillBody: Encodable {
        var name: String
        var description: String
        var content: String?
    }

    private struct ImportRemoteSkillBody: Encodable {
        var source: String
        var skillNames: [String]?
    }

    private struct DiscoverRemoteSkillsBody: Encodable {
        var source: String
    }

    private struct DiscoverRemoteSkillsResponse: Decodable {
        var skills: [ServerRemoteSkillCandidate]
    }

    private struct ImportSkillBody: Encodable {
        var path: String
    }

    private struct SetSkillInstalledBody: Encodable {
        var installed: Bool
    }

    private struct MakeSkillGlobalBody: Encodable {
        var harnessId: String
        var directoryName: String
    }

    private struct SyncSkillsBody: Encodable {
        var directoryNames: [String]?
    }

    public func createSkill(
        name: String,
        description: String,
        content: String?
    ) async throws -> ServerSkillsScan {
        try await send(
            "/v1/skills",
            method: "POST",
            body: CreateSkillBody(name: name, description: description, content: content)
        )
    }

    public func discoverRemoteSkills(source: String) async throws -> [ServerRemoteSkillCandidate] {
        let response: DiscoverRemoteSkillsResponse = try await send(
            "/v1/skills/discover-remote",
            method: "POST",
            body: DiscoverRemoteSkillsBody(source: source)
        )
        return response.skills
    }

    public func importRemoteSkill(source: String, skillNames: [String]?) async throws -> ServerSkillsScan {
        try await send(
            "/v1/skills/import-remote",
            method: "POST",
            body: ImportRemoteSkillBody(source: source, skillNames: skillNames)
        )
    }

    public func importSkill(path: String) async throws -> ServerSkillsScan {
        try await send("/v1/skills/import", method: "POST", body: ImportSkillBody(path: path))
    }

    public func removeSkill(directoryName: String) async throws -> ServerSkillsScan {
        try await send(
            "/v1/skills/\(pathComponent(directoryName))",
            method: "DELETE",
            body: Optional<EmptyBody>.none
        )
    }

    public func setSkillInstalled(
        directoryName: String,
        harnessId: String,
        installed: Bool
    ) async throws -> ServerSkillsScan {
        try await send(
            "/v1/skills/\(pathComponent(directoryName))/harnesses/\(pathComponent(harnessId))",
            method: "PUT",
            body: SetSkillInstalledBody(installed: installed)
        )
    }

    public func makeSkillGlobal(
        harnessId: String,
        directoryName: String
    ) async throws -> ServerSkillsScan {
        try await send(
            "/v1/skills/make-global",
            method: "POST",
            body: MakeSkillGlobalBody(harnessId: harnessId, directoryName: directoryName)
        )
    }

    public func syncSkills(directoryNames: [String]?) async throws -> ServerSkillsScan {
        try await send(
            "/v1/skills/sync",
            method: "POST",
            body: SyncSkillsBody(directoryNames: directoryNames)
        )
    }
}

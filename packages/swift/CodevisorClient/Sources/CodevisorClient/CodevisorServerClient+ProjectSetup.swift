import CodevisorProtocol
import Foundation

public struct ServerProjectEnvFile: Codable, Equatable, Hashable, Sendable, Identifiable {
  public var path: String
  public var size: Int

  public init(path: String, size: Int) {
    self.path = path
    self.size = size
  }

  public var id: String { path }
}

public struct ServerProjectEnvFileContent: Codable, Equatable, Sendable {
  public var path: String
  public var contents: String

  public init(path: String, contents: String) {
    self.path = path
    self.contents = contents
  }
}

public struct ServerProjectSetupSource: Decodable, Equatable, Sendable {
  public var projectId: String
  public var folderPath: String
  public var homeRelativePath: String?
  public var envFiles: [ServerProjectEnvFile]
  public var needsInitialCommit: Bool?

  public init(
    projectId: String,
    folderPath: String,
    homeRelativePath: String? = nil,
    envFiles: [ServerProjectEnvFile] = [],
    needsInitialCommit: Bool? = nil
  ) {
    self.projectId = projectId
    self.folderPath = folderPath
    self.homeRelativePath = homeRelativePath
    self.needsInitialCommit = needsInitialCommit
    self.envFiles = envFiles
  }
}

public struct ServerProjectSetupRequest: Encodable, Equatable, Sendable {
  public var id: String
  public var url: String
  public var name: String?
  public var homeRelativePath: String?
  public var envFiles: [ServerProjectEnvFileContent]?
  public var worktreeBase: ProjectWorktreeBase?
  public var defaultRunLocation: ProjectRunLocation?

  public init(
    id: UUID,
    url: String,
    name: String?,
    homeRelativePath: String? = nil,
    envFiles: [ServerProjectEnvFileContent]? = nil,
    worktreeBase: ProjectWorktreeBase? = nil,
    defaultRunLocation: ProjectRunLocation? = nil
  ) {
    self.id = id.uuidString
    self.url = url
    self.name = name
    self.homeRelativePath = homeRelativePath
    self.envFiles = envFiles
    self.worktreeBase = worktreeBase
    self.defaultRunLocation = defaultRunLocation
  }
}

public struct ServerProjectCloneSettings: Decodable, Equatable, Sendable {
  public var baseFolder: String
  public var defaultBaseFolder: String

  public init(baseFolder: String, defaultBaseFolder: String) {
    self.baseFolder = baseFolder
    self.defaultBaseFolder = defaultBaseFolder
  }
}

public struct ServerGitHostAuthStatus: Decodable, Equatable, Sendable {
  public var host: String
  public var provider: String?
  public var cli: String?
  public var cliInstalled: Bool
  public var supported: Bool
  public var signedIn: Bool
  public var account: String?

  public init(
    host: String,
    provider: String? = nil,
    cli: String? = nil,
    cliInstalled: Bool = false,
    supported: Bool = false,
    signedIn: Bool = false,
    account: String? = nil
  ) {
    self.host = host
    self.provider = provider
    self.cli = cli
    self.cliInstalled = cliInstalled
    self.supported = supported
    self.signedIn = signedIn
    self.account = account
  }
}

public struct ServerGitAuthFlow: Decodable, Equatable, Sendable, Identifiable {
  public enum State: String, Decodable, Sendable {
    case starting, waiting, complete, error, cancelled
  }

  public var id: String
  public var host: String
  public var provider: String
  public var state: State
  public var installing: Bool?
  public var userCode: String?
  public var verificationUrl: String?
  public var account: String?
  public var message: String?

  public init(
    id: String,
    host: String,
    provider: String,
    state: State,
    installing: Bool? = nil,
    userCode: String? = nil,
    verificationUrl: String? = nil,
    account: String? = nil,
    message: String? = nil
  ) {
    self.id = id
    self.host = host
    self.provider = provider
    self.state = state
    self.installing = installing
    self.userCode = userCode
    self.verificationUrl = verificationUrl
    self.account = account
    self.message = message
  }
}

private struct ReadProjectEnvFilesBody: Encodable {
  var paths: [String]
}

private struct PublishProjectRemoteBody: Encodable {
  var url: String
  var initialize: Bool
}

private struct ReadProjectEnvFilesResponse: Decodable {
  var files: [ServerProjectEnvFileContent]
}

private struct UpdateProjectCloneSettingsBody: Encodable {
  var baseFolder: String?

  private enum CodingKeys: String, CodingKey {
    case baseFolder
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(baseFolder, forKey: .baseFolder)
  }
}

private struct StartGitAuthBody: Encodable {
  var host: String
}

extension CodevisorServerClient {
  public func projectSetupSource(projectId: UUID) async throws -> ServerProjectSetupSource {
    try await get("/v1/projects/\(projectId.uuidString)/setup-source")
  }

  public func publishProjectRemote(projectId: UUID, url: String, initialize: Bool) async throws -> ServerProject {
    try await send(
      "/v1/projects/\(projectId.uuidString)/remote",
      method: "POST",
      body: PublishProjectRemoteBody(url: url, initialize: initialize),
      timeout: 600
    )
  }

  public func readProjectEnvFiles(
    projectId: UUID,
    paths: [String]
  ) async throws -> [ServerProjectEnvFileContent] {
    let response: ReadProjectEnvFilesResponse = try await send(
      "/v1/projects/\(projectId.uuidString)/env-files/read",
      method: "POST",
      body: ReadProjectEnvFilesBody(paths: paths)
    )
    return response.files
  }

  public func setUpProjectFromGit(_ request: ServerProjectSetupRequest) async throws -> ServerProject {
    try await send("/v1/projects/from-git", method: "POST", body: request, timeout: 1800)
  }

  public func cancelProjectSetup(id: UUID) async throws {
    try await sendNoResponse("/v1/projects/from-git/\(id.uuidString)", method: "DELETE")
  }

  public func projectCloneSettings() async throws -> ServerProjectCloneSettings {
    try await get("/v1/projects/clone-settings")
  }

  public func updateProjectCloneSettings(baseFolder: String?) async throws -> ServerProjectCloneSettings {
    try await send(
      "/v1/projects/clone-settings",
      method: "PUT",
      body: UpdateProjectCloneSettingsBody(baseFolder: baseFolder)
    )
  }

  public func gitAuthStatus(host: String) async throws -> ServerGitHostAuthStatus {
    var components = URLComponents()
    components.path = "/v1/git/auth/status"
    components.queryItems = [URLQueryItem(name: "host", value: host)]
    guard let path = components.string else {
      throw CodevisorServerClientError.invalidURL("git/auth/status")
    }
    return try await get(path)
  }

  public func startGitAuth(host: String) async throws -> ServerGitAuthFlow {
    try await send("/v1/git/auth/login", method: "POST", body: StartGitAuthBody(host: host))
  }

  public func gitAuthFlow(id: String) async throws -> ServerGitAuthFlow {
    try await get("/v1/git/auth/login/\(pathComponent(id))")
  }

  public func cancelGitAuth(id: String) async throws {
    try await sendNoResponse("/v1/git/auth/login/\(pathComponent(id))", method: "DELETE")
  }
}

import CodevisorProtocol
import Foundation

public extension CodevisorServerClienting {
  func projectSetupSource(projectId: UUID) async throws -> ServerProjectSetupSource {
    throw CodevisorServerClientError.invalidResponse
  }

  func readProjectEnvFiles(projectId: UUID, paths: [String]) async throws -> [ServerProjectEnvFileContent] {
    throw CodevisorServerClientError.invalidResponse
  }

  func publishProjectRemote(projectId: UUID, url: String, initialize: Bool) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }

  func setUpProjectFromGit(_ request: ServerProjectSetupRequest) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }

  func cancelProjectSetup(id: UUID) async throws {
    throw CodevisorServerClientError.invalidResponse
  }

  func projectCloneSettings() async throws -> ServerProjectCloneSettings {
    throw CodevisorServerClientError.invalidResponse
  }

  func updateProjectCloneSettings(baseFolder: String?) async throws -> ServerProjectCloneSettings {
    throw CodevisorServerClientError.invalidResponse
  }

  func gitAuthStatus(host: String) async throws -> ServerGitHostAuthStatus {
    throw CodevisorServerClientError.invalidResponse
  }

  func startGitAuth(host: String) async throws -> ServerGitAuthFlow {
    throw CodevisorServerClientError.invalidResponse
  }

  func gitAuthFlow(id: String) async throws -> ServerGitAuthFlow {
    throw CodevisorServerClientError.invalidResponse
  }

  func cancelGitAuth(id: String) async throws {
    throw CodevisorServerClientError.invalidResponse
  }
}

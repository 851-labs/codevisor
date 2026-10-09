import Foundation

/// Defaults for clients without skill management: an empty list and
/// explicit failures for unsupported operations.
public extension CodevisorServerClienting {
  func listSkills() async throws -> ServerSkillsList {
    ServerSkillsList()
  }

  /// Answers like a server that predates the endpoint, so callers fall
  /// back to `listSkills()`.
  func composerSkills(projectId: UUID?, sessionId: UUID?) async throws -> [ServerComposerSkill] {
    throw CodevisorServerClientError.httpStatus(404, "")
  }

  func skillContent(directoryName: String) async throws -> String {
    throw CodevisorServerClientError.invalidResponse
  }

  func updateSkill(directoryName: String, content: String) async throws -> ServerSkillsList {
    throw CodevisorServerClientError.invalidResponse
  }

  func createSkill(name: String, description: String, content: String?) async throws -> ServerSkillsList {
    throw CodevisorServerClientError.invalidResponse
  }

  func discoverRemoteSkills(source: String) async throws -> [ServerRemoteSkillCandidate] {
    throw CodevisorServerClientError.invalidResponse
  }

  func importRemoteSkill(source: String, skillNames: [String]?) async throws -> ServerSkillsList {
    throw CodevisorServerClientError.invalidResponse
  }

  func removeSkill(directoryName: String) async throws -> ServerSkillsList {
    throw CodevisorServerClientError.invalidResponse
  }
}

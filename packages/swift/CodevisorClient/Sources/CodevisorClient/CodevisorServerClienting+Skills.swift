/// Defaults for clients without skill management: an empty scan and
/// explicit failures for unsupported operations.
public extension CodevisorServerClienting {
  func listSkills() async throws -> ServerSkillsScan {
    ServerSkillsScan(canonicalDir: "", global: [], harnesses: [])
  }

  func skillContent(directoryName: String) async throws -> String {
    throw CodevisorServerClientError.invalidResponse
  }

  func updateSkill(directoryName: String, content: String) async throws -> ServerSkillsScan {
    throw CodevisorServerClientError.invalidResponse
  }

  func createSkill(name: String, description: String, content: String?) async throws -> ServerSkillsScan {
    throw CodevisorServerClientError.invalidResponse
  }

  func importSkill(path: String) async throws -> ServerSkillsScan {
    throw CodevisorServerClientError.invalidResponse
  }

  func discoverRemoteSkills(source: String) async throws -> [ServerRemoteSkillCandidate] {
    throw CodevisorServerClientError.invalidResponse
  }

  func importRemoteSkill(source: String, skillNames: [String]?) async throws -> ServerSkillsScan {
    throw CodevisorServerClientError.invalidResponse
  }

  func removeSkill(directoryName: String) async throws -> ServerSkillsScan {
    throw CodevisorServerClientError.invalidResponse
  }

  func setSkillInstalled(directoryName: String, harnessId: String, installed: Bool) async throws -> ServerSkillsScan {
    throw CodevisorServerClientError.invalidResponse
  }

  func makeSkillGlobal(harnessId: String, directoryName: String) async throws -> ServerSkillsScan {
    throw CodevisorServerClientError.invalidResponse
  }

  func syncSkills(directoryNames: [String]?) async throws -> ServerSkillsScan {
    throw CodevisorServerClientError.invalidResponse
  }
}

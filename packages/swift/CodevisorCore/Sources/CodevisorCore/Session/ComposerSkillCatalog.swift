import ACPKit
import Foundation

public enum ComposerSkillCatalog {
  public static func merge(native: SessionSkills?, codevisor: [ServerComposerSkill]) -> [SessionSkill] {
    let nativeSkills = native?.skills ?? []
    let prefix = native?.invocationPrefix ?? "/"
    let nativeNames = Set(nativeSkills.map { $0.name.lowercased() })
    let codevisorSkills = codevisor.compactMap { skill -> SessionSkill? in
      guard !nativeNames.contains(skill.name.lowercased()) else { return nil }
      return SessionSkill(
        name: skill.name,
        description: skill.description,
        invocation: prefix + skill.name,
        source: .codevisor
      )
    }
    return (nativeSkills + codevisorSkills).sorted { lhs, rhs in
      let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
      return order == .orderedSame ? lhs.invocation < rhs.invocation : order == .orderedAscending
    }
  }

  static func codevisorSkills(
    from client: any CodevisorServerClienting,
    projectId: UUID?,
    sessionId: UUID?
  ) async throws -> [ServerComposerSkill] {
    do {
      return try await client.composerSkills(projectId: projectId, sessionId: sessionId)
    } catch CodevisorServerClientError.httpStatus(404, _) {
      return try await client.listSkills().skills.compactMap { skill in
        guard skill.invalid != true, !legacyReservedSkillNames.contains(skill.directoryName) else { return nil }
        return ServerComposerSkill(name: skill.directoryName, description: skill.description)
      }
    }
  }

  private static let legacyReservedSkillNames: Set<String> = [
    "execute", "browser-use", "computer-use", "codevisor", "codevisor-agents",
    "codevisor-machines", "codevisor-clients", "attaching-files", "create-codevisor-plugin",
  ]

  public static func matches(_ skills: [SessionSkill], query: String) -> [SessionSkill] {
    guard !query.isEmpty else { return skills }
    var exact: [SessionSkill] = []
    var prefixed: [SessionSkill] = []
    var contained: [SessionSkill] = []
    for skill in skills {
      let name = skill.name.lowercased()
      if name == query {
        exact.append(skill)
      } else if name.hasPrefix(query) {
        prefixed.append(skill)
      } else if name.contains(query) {
        contained.append(skill)
      }
    }
    return exact + prefixed + contained
  }
}

public extension SessionSkillSource {
  var paletteLabel: String {
    switch self {
    case .builtin: "Built-in"
    case .project: "Project"
    case .user: "Personal"
    case .plugin: "Plugin"
    case .codevisor: "Codevisor"
    }
  }
}

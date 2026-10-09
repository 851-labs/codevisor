import ACPKit
import Foundation

/// The skills the composer palette offers: the harness's own (built-in,
/// project, user, plugin) plus the Codevisor skills the server offers the
/// chat. Harness commands that are not skills never appear here.
public enum ComposerSkillCatalog {
  /// Merges the harness's skills with Codevisor's, sorted by name.
  /// Codevisor skills are invoked by their gateway name behind the
  /// harness's prefix; a harness skill with the same name wins, because
  /// that is the one the harness would run.
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

  /// The Codevisor skills `client`'s machine offers a chat. A server that
  /// predates `GET /v1/composer-skills` answers 404; its store skills
  /// stand in, minus invalid entries and the gateway's reserved names.
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

  /// Names older servers' tool gateways reserve for their built-in skills;
  /// newer servers filter these themselves.
  private static let legacyReservedSkillNames: Set<String> = [
    "execute", "browser-use", "computer-use", "codevisor", "codevisor-agents",
    "codevisor-machines", "codevisor-clients", "attaching-files", "create-codevisor-plugin",
  ]

  /// Skills whose name matches a lowercased query: exact matches first,
  /// then prefix matches, then names containing the query, each tier in
  /// catalog order. An empty query matches everything.
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
  /// The palette row's trailing label.
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

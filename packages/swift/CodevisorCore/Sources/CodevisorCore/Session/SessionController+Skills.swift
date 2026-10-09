import Foundation
import ACPKit

extension SessionController {
  // MARK: - Composer skills

  /// The skills the composer palette offers, sorted by name: the session's
  /// latest skill update once the harness has reported one, otherwise the
  /// capability inspection for this chat's directory and harness, plus the
  /// Codevisor skills the machine offers this chat behind the harness's
  /// prefix.
  public var composerSkills: [SessionSkill] {
    ComposerSkillCatalog.merge(
      native: availableSkills ?? inspectedSkills,
      codevisor: configCache.codevisorSkills(for: codevisorSkillsScope)
    )
  }

  /// Refreshes this chat's Codevisor skills in the background. The palette
  /// calls this as it opens; the list it shows meanwhile is the last one
  /// fetched for this project and chat (or none).
  @discardableResult
  public func refreshCodevisorSkills() -> Task<Void, Never>? {
    guard let serverClient else { return nil }
    let scope = codevisorSkillsScope
    return configCache.refreshCodevisorSkills(for: scope) {
      try await ComposerSkillCatalog.codevisorSkills(
        from: serverClient,
        projectId: scope.projectId,
        sessionId: scope.sessionId
      )
    }
  }

  /// The server resolves Codevisor skills from the project's MCP servers
  /// and, once the chat exists there, its own overrides. A "No project"
  /// draft has no project on the server yet; the machine's defaults apply.
  private var codevisorSkillsScope: ConfigOptionCache.CodevisorSkillsScope {
    ConfigOptionCache.CodevisorSkillsScope(
      serverId: project.serverId,
      projectId: project.isRunTargetPlaceholder ? nil : project.id,
      sessionId: serverSession?.id
    )
  }

  /// A draft inspects its project folder (see `prepare()`); an existing
  /// chat inspects its own working directory.
  private var inspectedSkills: SessionSkills? {
    guard let harnessId = connectedHarnessId ?? selectedHarnessId else { return nil }
    return configCache.skills(
      forHarness: harnessId,
      onServer: project.serverId,
      cwd: hasExistingAgentSession ? sessionCwdURL.path : capabilityCwd
    )
  }
}

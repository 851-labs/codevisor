import Foundation
import ACPKit

extension SessionController {
  public var offersSlashCommands: Bool { !project.isBot }

  public var composerSkills: [SessionSkill] {
    ComposerSkillCatalog.merge(
      native: availableSkills ?? inspectedSkills,
      codevisor: configCache.codevisorSkills(for: codevisorSkillsScope)
    )
  }

  public var supportsCompaction: Bool {
    guard !project.isBot, hasSentFirst || hasExistingAgentSession else { return false }
    return nativeSkills?.acceptsCompact == true
  }

  public var supportsFork: Bool {
    guard !project.isBot, hasExistingAgentSession, !canStop else { return false }
    return nativeSkills?.acceptsFork == true
  }

  private var nativeSkills: SessionSkills? { availableSkills ?? inspectedSkills }

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

  private var codevisorSkillsScope: ConfigOptionCache.CodevisorSkillsScope {
    ConfigOptionCache.CodevisorSkillsScope(
      serverId: project.serverId,
      projectId: project.isRunTargetPlaceholder ? nil : project.id,
      sessionId: serverSession?.id
    )
  }

  private var inspectedSkills: SessionSkills? {
    guard let harnessId = connectedHarnessId ?? selectedHarnessId else { return nil }
    return configCache.skills(
      forHarness: harnessId,
      onServer: project.serverId,
      cwd: hasExistingAgentSession ? sessionCwdURL.path : capabilityCwd
    )
  }
}

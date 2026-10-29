import CodevisorClient
import Foundation

extension SessionController {
  public var sandboxTargetAvailability: SandboxProfileAvailability? {
    guard !hasSentFirst, let sandboxTarget else { return nil }
    if sandboxPrewarm?.key.target == sandboxTarget { return .available }
    return machines?.sandboxProfiles.availability(of: sandboxTarget.profileId, for: project.serverId) ?? .available
  }

  public func presentedSandboxChoices(_ choices: [SandboxProfileChoice]) -> [SandboxProfileChoice] {
    choices.map { choice in
      guard choice.id == sandboxTarget?.profileId, let selected = sandboxTargetAvailability else { return choice }
      return SandboxProfileChoice(target: choice.target, availability: selected)
    }
  }

  public var sandboxUnavailableMessage: String? {
    guard let sandboxTarget else { return nil }
    switch sandboxTargetAvailability {
    case let .unavailable(reason): return "\(sandboxTarget.profileName) can't start. \(reason)."
    case let .full(reason): return "\(sandboxTarget.profileName) is full. \(reason)."
    case .checking, .available, nil: return nil
    }
  }

  public var isSandboxTargetFull: Bool {
    if case .full = sandboxTargetAvailability { return true }
    return false
  }

  public func refreshSandboxPrewarm() {
    guard !hasSentFirst else { return }
    let wanted = prewarmKey(for: sandboxTarget)
    guard sandboxPrewarm?.key != wanted else { return }

    abandonSandboxPrewarm()
    guard let wanted, sandboxTargetAvailability == .available, let client = sandboxClient(for: wanted.target)
    else { return }
    sandboxPrewarm = SandboxPrewarm(key: wanted, project: project, harnessId: selectedHarnessId, client: client)
  }

  func sandboxClient(for target: SandboxTarget) -> (any CodevisorServerClienting)? {
    guard let host = target.hostMachineId else { return serverClient }
    return machines?.client(forServerId: host)
  }

  public func abandonSandboxPrewarm() {
    sandboxPrewarm?.abandon()
    sandboxPrewarm = nil
  }

  func takeSandboxPrewarm(
    for target: SandboxTarget,
    client: any CodevisorServerClienting
  ) -> SandboxPrewarm? {
    guard let key = prewarmKey(for: target) else { return nil }
    if let prewarm = sandboxPrewarm, prewarm.key == key {
      sandboxPrewarm = nil
      return prewarm
    }
    abandonSandboxPrewarm()
    return SandboxPrewarm(key: key, project: project, harnessId: selectedHarnessId, client: client)
  }

  private func prewarmKey(for target: SandboxTarget?) -> SandboxPrewarm.Key? {
    guard let target, !project.isScratch, !project.isRunTargetPlaceholder else { return nil }
    return SandboxPrewarm.Key(target: target, projectId: project.id)
  }
}

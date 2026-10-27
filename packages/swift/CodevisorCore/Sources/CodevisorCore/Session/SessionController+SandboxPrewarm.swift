import CodevisorClient
import Foundation

extension SessionController {
  func refreshSandboxPrewarm() {
    guard !hasSentFirst else { return }
    let wanted = prewarmKey(for: sandboxTarget)
    guard sandboxPrewarm?.key != wanted else { return }

    abandonSandboxPrewarm()
    guard let wanted, let client = sandboxClient(for: wanted.target) else { return }
    sandboxPrewarm = SandboxPrewarm(key: wanted, project: project, harnessId: selectedHarnessId, client: client)
  }

  func sandboxClient(for target: SandboxTarget) -> (any CodevisorServerClienting)? {
    guard let host = target.hostMachineId else { return serverClient }
    return serverClientForMachine?(host)
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

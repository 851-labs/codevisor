import CodevisorClient
import Foundation

extension SessionController {
  func refreshSandboxPrewarm() {
    guard !hasSentFirst else { return }
    let wanted = prewarmKey(for: sandboxTarget)
    guard sandboxPrewarm?.key != wanted else { return }

    abandonSandboxPrewarm()
    guard let wanted, let serverClient else { return }
    sandboxPrewarm = SandboxPrewarm(key: wanted, harnessId: selectedHarnessId, client: serverClient)
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
    return SandboxPrewarm(key: key, harnessId: selectedHarnessId, client: client)
  }

  private func prewarmKey(for target: SandboxTarget?) -> SandboxPrewarm.Key? {
    guard let target, !project.isScratch, !project.isRunTargetPlaceholder else { return nil }
    return SandboxPrewarm.Key(target: target, projectId: project.id)
  }
}

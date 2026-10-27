import CodevisorClient
import Foundation

extension SessionController {
  func refreshEphemeralPrewarm() {
    let wanted = hasSentFirst ? nil : prewarmKey(for: ephemeralTarget)
    guard ephemeralPrewarm?.key != wanted else { return }

    abandonEphemeralPrewarm()
    guard let wanted, let serverClient else { return }
    ephemeralPrewarm = EphemeralPrewarm(key: wanted, harnessId: selectedHarnessId, client: serverClient)
  }

  public func abandonEphemeralPrewarm() {
    ephemeralPrewarm?.abandon()
    ephemeralPrewarm = nil
  }

  func takeEphemeralPrewarm(
    for target: EphemeralTarget,
    client: any CodevisorServerClienting
  ) -> EphemeralPrewarm? {
    guard let key = prewarmKey(for: target) else { return nil }
    if let prewarm = ephemeralPrewarm, prewarm.key == key {
      ephemeralPrewarm = nil
      return prewarm
    }
    abandonEphemeralPrewarm()
    return EphemeralPrewarm(key: key, harnessId: selectedHarnessId, client: client)
  }

  private func prewarmKey(for target: EphemeralTarget?) -> EphemeralPrewarm.Key? {
    guard let target, !project.isScratch, !project.isRunTargetPlaceholder else { return nil }
    return EphemeralPrewarm.Key(target: target, projectId: project.id)
  }
}

import Foundation

@MainActor
final class CloudPresenceRefresh {
  private nonisolated static let settleDelay: Duration = .milliseconds(300)

  private(set) var task: Task<Void, Never>?
  private let sleep: @Sendable (Duration) async throws -> Void

  init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
    self.sleep = sleep
  }

  func reconcile(_ reported: [CloudMachine], for account: CloudAccountController) {
    guard account.state.isSignedIn else { return }
    guard Self.reachabilityDiffers(known: account.machines, reported: reported) else { return }
    guard task == nil else { return }

    let sleep = sleep
    task = Task { [weak self, weak account] in
      try? await sleep(Self.settleDelay)
      guard let self, let account, !Task.isCancelled else { return }
      self.task = nil
      await account.refreshMachines()
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  nonisolated static func reachabilityDiffers(known: [CloudMachine], reported: [CloudMachine]) -> Bool {
    let knownReach = Dictionary(
      known.map { ($0.deviceId, reach($0)) },
      uniquingKeysWith: { first, _ in first }
    )
    return reported.contains(where: { knownReach[$0.deviceId] != reach($0) })
  }

  private nonisolated static func reach(_ machine: CloudMachine) -> String {
    "\(machine.online)|\(machine.tunnel?.endpointId ?? "")"
  }
}

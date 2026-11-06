import Foundation

@MainActor
public struct MachineRetry {
  public let machineId: String
  private let machines: MachineController
  private let policy: RetryPolicy

  public init(machineId: String, machines: MachineController, policy: RetryPolicy = .standard) {
    self.machineId = machineId
    self.machines = machines
    self.policy = policy
  }

  public func client() -> any CodevisorServerClienting {
    machines.client(for: machineId)
  }

  public func shouldRetry(after error: any Error, failures: Int) async -> Bool {
    guard !CodevisorServerClientError.isRefusal(error) else { return false }

    return await wait(afterFailures: failures)
  }

  public func wait(afterFailures failures: Int) async -> Bool {
    let delay = policy.delay(afterFailures: failures)
    let woke = await firstWake(after: delay)
    return woke && !Task.isCancelled
  }

  private func firstWake(after delay: Duration) async -> Bool {
    await withTaskGroup(of: Bool.self) { [policy, machines, machineId] group in
      group.addTask { (try? await policy.clock.sleep(for: delay)) != nil }
      group.addTask {
        await machines.connectSignal.next(for: machineId)
        return true
      }
      let woke = await group.next() ?? false
      group.cancelAll()
      return woke
    }
  }
}

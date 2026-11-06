import Foundation

@MainActor
final class MachineConnectSignal {
  private var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]

  func next(for machineId: String) async {
    let waiterId = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { return continuation.resume() }

        waiters[machineId, default: [:]][waiterId] = continuation
      }
    } onCancel: {
      Task { @MainActor in self.release(waiterId, on: machineId) }
    }
  }

  func fire(for machineId: String) {
    let released = waiters.removeValue(forKey: machineId) ?? [:]
    for continuation in released.values { continuation.resume() }
  }

  private func release(_ waiterId: UUID, on machineId: String) {
    waiters[machineId]?.removeValue(forKey: waiterId)?.resume()
  }
}

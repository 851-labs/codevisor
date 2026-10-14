import Foundation

extension MachineController {
  public func refreshNavigation() async {
    await refreshNavigation(sleep: { try await Task.sleep(for: $0) })
  }

  func refreshNavigation(
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) async {
    guard !Task.isCancelled else { return }
    let answering = Set(allMachines.filter { connectionsById[$0.id]?.availability == .ready }.map(\.id))
    let refreshes = allMachines.compactMap { machine -> MachineNavigationRefresh? in
      let refresh = manualRefresh(for: machine.id)
      return answering.contains(machine.id) ? refresh : nil
    }
    guard !refreshes.isEmpty else { return }

    let observerID = UUID()
    let (completions, continuation) = AsyncStream<Void>.makeStream()
    for refresh in refreshes {
      refresh.observeCompletion(id: observerID, continuation: continuation)
    }
    let deadline = Task {
      do {
        try await sleep(.seconds(5))
        continuation.finish()
      } catch {
      }
    }
    defer {
      deadline.cancel()
      continuation.finish()
      for refresh in refreshes { refresh.removeObserver(id: observerID) }
    }

    var remaining = refreshes.count
    for await _ in completions {
      remaining -= 1
      if remaining == 0 { break }
    }
  }

  private func manualRefresh(for machineId: String) -> MachineNavigationRefresh {
    let connection = connection(for: machineId)
    if let existing = connection.manualNavigationRefresh { return existing }
    let refresh = MachineNavigationRefresh()
    connection.manualNavigationRefresh = refresh
    refresh.task = Task { [weak self] in
      defer {
        refresh.finish()
        if connection.manualNavigationRefresh === refresh {
          connection.manualNavigationRefresh = nil
        }
      }
      guard let self, !Task.isCancelled else { return }
      if let preparation = connection.preparationTask {
        await preparation.value
      } else if case .failed = connection.availability {
        await self.prepareMachine(machineId)
      } else {
        await self.refreshNavigationState(for: machineId)
      }
    }
    return refresh
  }
}

@MainActor
final class MachineNavigationRefresh {
  var task: Task<Void, Never>?
  private var finished = false
  private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

  func observeCompletion(id: UUID, continuation: AsyncStream<Void>.Continuation) {
    if finished {
      continuation.yield(())
    } else {
      observers[id] = continuation
    }
  }

  func removeObserver(id: UUID) {
    observers.removeValue(forKey: id)
  }

  func finish() {
    guard !finished else { return }
    finished = true
    for observer in observers.values { observer.yield(()) }
    observers.removeAll()
    task = nil
  }

  func cancel() {
    task?.cancel()
    finish()
  }
}

import Foundation

extension MachineController {
  /// Refresh every machine concurrently, showing the native refresh control
  /// until the machines that are answering have finished. Machines that are
  /// offline or still connecting are refreshed too, but the gesture doesn't
  /// wait for them -- it used to, which made every pull take the full five
  /// seconds whenever one machine was away. Five seconds remains the cap.
  /// Slow work continues under each machine's existing lifecycle, and a
  /// later pull reuses work that is still in flight.
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
        // Finishing early cancels only this presentation deadline.
      }
    }
    defer {
      deadline.cancel()
      continuation.finish()
      for refresh in refreshes { refresh.removeObserver(id: observerID) }
    }

    // AsyncStream cancellation ends this wait immediately, even if a shared
    // preparation or snapshot ignores cancellation. A task-group race would
    // still wait for its network child to exit before dismissing refresh.
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
        // Re-preparation clears the failed request gate before retrying.
        await self.prepareMachine(machineId)
      } else {
        await self.refreshNavigationState(for: machineId)
      }
    }
    return refresh
  }
}

/// One owned operation per machine, with removable completion observers.
/// Repeated gestures cannot accumulate tasks waiting on a stuck request.
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

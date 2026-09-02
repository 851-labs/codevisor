import Foundation

// MARK: - Machine preparation

extension MachineController {
  /// Starts and connects exactly one machine. For the local machine this
  /// owns the app/LaunchAgent lifecycle; remote machines are only probed and
  /// synchronized. Concurrent callers for the same id share one task.
  public func prepareMachine(_ machineId: String) async {
    guard let machine = machine(for: machineId) else { return }
    let connection = connection(for: machineId)
    if let preparationTask = connection.preparationTask {
      await preparationTask.value
      return
    }
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performPreparation(
        for: machine,
        client: self.client(for: machineId)
      )
    }
    connection.preparationTask = task
    await task.value
    connection.preparationTask = nil
  }

  /// Bootstraps every known machine independently. A slow or unavailable
  /// remote can never prevent the local LaunchAgent from being restored,
  /// and the remembered composer target has no bearing on this work.
  public func prepareAllMachines() async {
    let ids = allMachines.map(\.id)
    await withTaskGroup(of: Void.self) { group in
      for id in ids {
        group.addTask { await self.prepareMachine(id) }
      }
    }
  }

  private func performPreparation(
    for machine: CodevisorMachine,
    client: any CodevisorServerClienting
  ) async {
    let machineId = machine.id
    beginWaiting(for: machineId, reason: machine.isLocal ? .starting : .connecting)
    // A machine that is already `.current` stays `.current` through a
    // warm re-preparation (foreground recovery): its cached rows are
    // honest and the resync is gapless, so evicting them from
    // fleet-aggregated lists just to reinsert seconds later is churn.
    if connection(for: machineId).navigationSyncState != .current {
      connection(for: machineId).navigationSyncState = .catchingUp
    }

    if machine.isLocal, let localServer {
      let serverState = await localServer.ensureRunning()
      if case let .unavailable(message) = serverState {
        markFailed(for: machineId, message: message)
        connection(for: machineId).status = MachineStatus(
          isReachable: false,
          label: message
        )
        return
      }
      if serverState == .alreadyRunning {
        // The durable server's PATH is frozen at its launch; a CLI
        // installed since then (followed by an app relaunch) stays
        // invisible to it. Fire one rescan so it re-resolves PATH —
        // off the critical path so machine prep isn't delayed.
        Task {
          do {
            _ = try await client.rescanHarnesses()
          } catch {
            Log.machines.error("Harness rescan failed: \(String(describing: error), privacy: .public)")
          }
        }
      }
    } else {
      do {
        // Unlike health, info also proves this device's connection
        // token is accepted before ordinary requests are released.
        _ = try await client.info()
      } catch {
        let message = serverErrorMessage(error)
        markFailed(for: machineId, message: message)
        connection(for: machineId).status = MachineStatus(
          isReachable: false,
          label: message
        )
        // Remote failures are routinely transient (a relay timeout
        // against a machine mid-handoff, a stale direct pipe): keep
        // retrying with backoff instead of parking the machine in a
        // latched failure until the next foreground.
        schedulePreparationRetry(for: machineId)
        return
      }
    }

    markReady(for: machineId)
    await refreshStatus(for: machineId)
    await synchronizeNavigationState(
      serverId: machineId,
      client: client,
      presentation: .catchUp
    )
    onMachineConnected?(machineId)
  }
}

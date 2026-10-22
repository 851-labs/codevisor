import Foundation

extension MachineController {
  public func prepareMachine(_ machineId: String) async {
    guard let machine = machine(for: machineId) else { return }
    let connection = connection(for: machineId)
    if let preparationTask = connection.preparation.task {
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
    connection.preparation.task = task
    await task.value
    connection.preparation.task = nil
  }

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

    if machine.isLocal, let localServer {
      let serverState = await localServer.ensureRunning()
      if case let .unavailable(message) = serverState {
        markFailed(for: machineId, message: message)
        connection(for: machineId).status = MachineStatus(
          isReachable: false,
          label: message
        )
        schedulePreparationRetry(for: machineId)
        return
      }
      if serverState == .alreadyRunning {
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
        _ = try await client.info()
      } catch {
        if await probeDataUpgrade(for: machineId, client: client) != nil {
          let label = connection(for: machineId).status?.label ?? "Updating server data…"
          markFailed(for: machineId, message: label)
          schedulePreparationRetry(for: machineId, delay: updatePollInterval)
          return
        }
        let message = serverErrorMessage(error)
        markFailed(for: machineId, message: message)
        connection(for: machineId).status = MachineStatus(
          isReachable: false,
          label: message
        )
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

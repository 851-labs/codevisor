import Foundation

extension MachineController {
  public var isAnyServerUpdating: Bool {
    connectionsById.values.contains { $0.updatePhase == .updating }
  }

  public func refreshServerUpdates(force: Bool = false) async {
    let machineIds = allMachines.map(\.id).filter { id in
      connectionsById[id]?.status?.isReachable == true
        && connectionsById[id]?.updatePhase != .updating
    }
    for machineId in machineIds {
      let client = client(for: machineId)
      guard
        let update = try? await client.updateInfo(
          refresh: force,
          channel: serverUpdateChannel
        )
      else { continue }
      connection(for: machineId).updateInfo = update
    }
  }

  public func updateServer(machineId: String) async {
    let connection = connection(for: machineId)
    guard connection.updatePhase != .updating else { return }

    let client = client(for: machineId)
    let run = ServerUpdateRun(
      connection: connection,
      client: client,
      channel: serverUpdateChannel,
      machine: updateMachine(for: machineId, client: client),
      scheduler: updateScheduler,
      pollInterval: updatePollInterval,
      pollAttempts: updatePollAttempts
    )
    await run.perform()
  }

  private func updateMachine(
    for machineId: String, client: any CodevisorServerClienting
  ) -> ServerUpdateRun.Machine {
    ServerUpdateRun.Machine(
      beginWaiting: { self.beginWaiting(for: machineId, reason: .updating) },
      markReady: { self.markReady(for: machineId) },
      markFailed: { self.markFailed(for: machineId, message: $0) },
      scheduleRecovery: { self.scheduleRemoteRecovery(for: machineId) },
      resumeEventStream: { self.resumeEventStream(for: machineId) },
      refreshStatus: { await self.refreshStatus(for: machineId) },
      refreshNavigation: { await self.refreshNavigationState(for: machineId) },
      probeDataUpgrade: { await self.probeDataUpgrade(for: machineId, client: client) }
    )
  }

  private func resumeEventStream(for machineId: String) {
    Task { await self.connectMachine(machineId) }
  }
}

import Foundation

extension MachineController {
  static let deviceOfflineMessage = "You're offline"

  public func prepareMachine(_ machineId: String) async {
    guard machine(for: machineId) != nil else { return }

    await connection(for: machineId).reconnector.connect()
  }

  public func prepareAllMachines() async {
    let ids = allMachines.map(\.id)
    await withTaskGroup(of: Void.self) { group in
      for id in ids {
        group.addTask { await self.prepareMachine(id) }
      }
    }
  }

  func attemptConnection(_ machineId: String) async -> MachineReconnector.Outcome {
    guard let machine = machine(for: machineId) else { return .failed }

    let client = client(for: machineId)
    beginWaiting(for: machineId, reason: machine.isLocal ? .starting : .connecting)
    if let unreached = await reachServer(machine, client: client) { return unreached }
    guard !Task.isCancelled else { return .failed }

    markReady(for: machineId)
    await refreshStatus(for: machineId)
    await synchronizeNavigationState(serverId: machineId, client: client, presentation: .catchUp)
    guard !Task.isCancelled else { return .failed }
    guard !connection(for: machineId).reconnector.wasLostDuringAttempt else {
      markUnreachable(machineId, message: unreachableMessage(for: machine, error: URLError(.networkConnectionLost)))
      return .failed
    }

    onMachineConnected?(machineId)
    return .connected
  }

  private func reachServer(
    _ machine: CodevisorMachine, client: any CodevisorServerClienting
  ) async -> MachineReconnector.Outcome? {
    if machine.isLocal, let localServer {
      return await startLocalServer(localServer, machineId: machine.id, client: client)
    }
    do {
      _ = try await client.info()
      return nil
    } catch {
      return await unreachable(machine, client: client, error: error)
    }
  }

  private func startLocalServer(
    _ localServer: any LocalServerControlling, machineId: String, client: any CodevisorServerClienting
  ) async -> MachineReconnector.Outcome? {
    let serverState = await localServer.ensureRunning()
    guard !Task.isCancelled else { return .failed }
    if case let .unavailable(message) = serverState {
      markUnreachable(machineId, message: message)
      return .failed
    }
    await waitForGit(on: machineId, client: client)
    guard !Task.isCancelled else { return .failed }
    if serverState == .alreadyRunning { rescanHarnesses(client) }
    return nil
  }

  private func waitForGit(on machineId: String, client: any CodevisorServerClienting) async {
    let connection = connection(for: machineId)
    defer { connection.isWaitingForGit = false }
    while !Task.isCancelled, await isGitMissing(client) {
      connection.isWaitingForGit = true
      try? await updateScheduler.sleep(updatePollInterval)
    }
  }

  private func isGitMissing(_ client: any CodevisorServerClienting) async -> Bool {
    (try? await client.health())?.isGitMissing == true
  }

  private func unreachable(
    _ machine: CodevisorMachine, client: any CodevisorServerClienting, error: any Error
  ) async -> MachineReconnector.Outcome {
    guard !Task.isCancelled else { return .failed }
    if await probeDataUpgrade(for: machine.id, client: client) != nil {
      markFailed(for: machine.id, message: connection(for: machine.id).status?.label ?? "Updating server data…")
      return .busy(retryAfter: updatePollInterval)
    }
    markUnreachable(machine.id, message: unreachableMessage(for: machine, error: error))
    return .failed
  }

  private func markUnreachable(_ machineId: String, message: String) {
    markFailed(for: machineId, message: message)
    connection(for: machineId).status = MachineStatus(isReachable: false, label: message)
  }

  private func unreachableMessage(for machine: CodevisorMachine, error: any Error) -> String {
    if isDeviceOffline, !machine.isLocal { return Self.deviceOfflineMessage }
    if cloudMachine(forMachineId: machine.id)?.online == false { return "\(machine.name) is offline" }
    return serverErrorMessage(error)
  }

  private func rescanHarnesses(_ client: any CodevisorServerClienting) {
    Task {
      do {
        _ = try await client.rescanHarnesses()
      } catch {
        Log.machines.error("Harness rescan failed: \(String(describing: error), privacy: .public)")
      }
    }
  }
}

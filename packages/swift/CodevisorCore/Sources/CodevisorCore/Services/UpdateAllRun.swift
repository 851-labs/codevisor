import Foundation

@MainActor
struct UpdateAllRun {
  let center: UpdateCenter
  let machines: MachineController
  let snapshot: [UpdateComponent]
  let pollInterval: Duration
  let pollAttempts: Int

  func perform() async {
    var remaining = Set(snapshot.map(\.id))
    center.persistSession(remaining)
    let plan = UpdateAllPlan(snapshot)
    for machine in plan.machines {
      guard await update(machine) else { return center.clearSession() }
      remaining.subtract(machine.componentIds)
      center.persistSession(remaining)
    }
    if !plan.includesApp { center.clearSession() }
  }

  private func update(_ machine: UpdateAllPlan.Machine) async -> Bool {
    if machine.harnesses.isEmpty { return await updateCodevisor(machine) }
    if machine.server != nil {
      await machines.updateServer(machineId: machine.machineId, harnessIds: machine.harnessIds)
      return true
    }
    guard let app = machine.app else {
      await updateHarnesses(machine, holdForAppUpdate: false)
      return true
    }
    return await updateHarnessesThenApp(machine, app: app)
  }

  private func updateCodevisor(_ machine: UpdateAllPlan.Machine) async -> Bool {
    if let server = machine.server { await center.install(server) }
    guard let app = machine.app else { return true }
    guard noEarlierFailure() else { return false }

    await center.install(app)
    return true
  }

  private func updateHarnessesThenApp(_ machine: UpdateAllPlan.Machine, app: UpdateComponent) async -> Bool {
    let held = await updateHarnesses(machine, holdForAppUpdate: true)
    guard held?.isHoldingForAppUpdate == true else { return false }
    guard noEarlierFailure() else {
      try? await machines.client(for: machine.machineId).cancelRestartDrain()
      return false
    }

    await center.install(app)
    return true
  }

  @discardableResult
  private func updateHarnesses(
    _ machine: UpdateAllPlan.Machine,
    holdForAppUpdate: Bool
  ) async -> ServerUpdateRunState? {
    let client = machines.client(for: machine.machineId)
    let request = ServerUpdateRunRequest(harnessIds: machine.harnessIds, holdForAppUpdate: holdForAppUpdate)
    do {
      let started = try await client.startUpdateRun(request)
      machines.connection(for: machine.machineId).updateRun = started.run
    } catch CodevisorServerClientError.httpStatus(404, _) {
      for harness in machine.harnesses { await center.install(harness) }
      return .idle
    } catch {
      for harness in machine.harnesses { center.transientPhases[harness.id] = .failed(serverErrorMessage(error)) }
      return nil
    }
    return await waitForUpdateRun(onMachine: machine.machineId, holdingForAppUpdate: holdForAppUpdate)
  }

  private func noEarlierFailure() -> Bool {
    guard let failure = firstFailure() else { return true }

    center.updateAllNotice =
      "Codevisor was not restarted because \(failure.title) on \(failure.machineName) failed to update. Fix that, then update again."
    return false
  }

  private func firstFailure() -> UpdateComponent? {
    let ids = Set(snapshot.map(\.id))
    return center.components.first { component in
      guard ids.contains(component.id), component.kind != .app, component.kind != .harness else { return false }
      if case .failed = component.phase { return true }
      return false
    }
  }

  private func waitForUpdateRun(onMachine machineId: String, holdingForAppUpdate: Bool) async -> ServerUpdateRunState? {
    let client = machines.client(for: machineId)
    for attempt in 0..<pollAttempts {
      if attempt > 0 {
        try? await machines.updateScheduler.sleep(pollInterval)
      }
      await center.refreshHarnesses(onMachine: machineId)
      guard let run = try? await client.updateRunState() else { continue }
      machines.connection(for: machineId).updateRun = run
      if settled(run, holdingForAppUpdate: holdingForAppUpdate) { return run }
    }
    return nil
  }

  private func settled(_ run: ServerUpdateRunState, holdingForAppUpdate: Bool) -> Bool {
    run.isIdle || (holdingForAppUpdate && run.isHoldingForAppUpdate)
  }
}

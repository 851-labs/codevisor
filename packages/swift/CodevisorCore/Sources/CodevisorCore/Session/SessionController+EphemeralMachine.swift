import Foundation

struct EphemeralMachineSetupError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

extension SessionController {
  func createRequestedEphemeralMachine(showsSetupPhases: Bool, restoreComposer: () -> Void) async -> Bool {
    guard let ephemeralTarget else { return true }
    guard let failure = await ephemeralMachineFailure(ephemeralTarget, showsSetupPhases: showsSetupPhases)
    else { return true }

    restoreComposer()
    handleSetupFailure(failure, returnsToNewChat: showsSetupPhases)
    return false
  }

  private func ephemeralMachineFailure(_ target: EphemeralTarget, showsSetupPhases: Bool) async -> String? {
    if project.isScratch || project.isRunTargetPlaceholder {
      return "Choose a project to run on a \(target.machineNoun)."
    }
    return await startEphemeralMachine(target, showsSetupPhases: showsSetupPhases)
  }

  private func startEphemeralMachine(_ target: EphemeralTarget, showsSetupPhases: Bool) async -> String? {
    guard let serverClient else {
      return "Ephemeral machines need the Codevisor server. Start it and try again."
    }
    let steps = EphemeralSetupSteps(target: target, projectName: project.name)
    status = .connecting(steps.status(.starting))
    var createdId: String?
    do {
      let created = try await serverClient.createEphemeralMachine(
        provider: target.providerId,
        projectId: project.id,
        workspaceId: hostWorkspaceId
      )
      createdId = created.id
      let ready = try await awaitEphemeralMachine(
        created.id, client: serverClient, steps: steps, showsSetupPhases: showsSetupPhases)
      try await adoptEphemeralMachine(ready, target: target)
      return nil
    } catch {
      if let createdId { try? await serverClient.destroyEphemeralMachine(id: createdId) }
      return serverErrorMessage(error)
    }
  }

  private func awaitEphemeralMachine(
    _ id: String,
    client: any CodevisorServerClienting,
    steps: EphemeralSetupSteps,
    showsSetupPhases: Bool
  ) async throws -> ServerEphemeralMachine {
    var current: EphemeralSetupStage?
    let deadline = ContinuousClock.now + .seconds(30 * 60)
    while ContinuousClock.now < deadline {
      let machine = try await ephemeralMachine(id, client: client)
      if let failure = Self.ephemeralFailure(machine) {
        failEphemeralStage(current, message: failure, showsSetupPhases: showsSetupPhases)
        throw EphemeralMachineSetupError(message: failure)
      }
      let next = EphemeralSetupStage(serverState: machine.state)
      applyEphemeralTransitions(
        EphemeralSetupSteps.transitions(from: current, to: next), steps: steps, showsSetupPhases: showsSetupPhases)
      current = next ?? current
      if machine.state == "ready" { return machine }
      try await Task.sleep(for: .seconds(1))
    }
    throw EphemeralMachineSetupError(message: "The \(steps.target.machineNoun) took too long to start")
  }

  private func ephemeralMachine(
    _ id: String,
    client: any CodevisorServerClienting
  ) async throws -> ServerEphemeralMachine {
    guard let machine = try await client.ephemeralMachines().first(where: { $0.id == id }) else {
      throw EphemeralMachineSetupError(message: "The ephemeral machine was removed before it was ready")
    }
    return machine
  }

  private static func ephemeralFailure(_ machine: ServerEphemeralMachine) -> String? {
    switch machine.state {
    case "failed": machine.error ?? "The ephemeral machine could not be set up"
    case "destroying": "The ephemeral machine is being destroyed"
    default: nil
    }
  }

  private func applyEphemeralTransitions(
    _ transitions: [EphemeralSetupTransition],
    steps: EphemeralSetupSteps,
    showsSetupPhases: Bool
  ) {
    for transition in transitions {
      switch transition {
      case let .begin(stage):
        status = .connecting(steps.status(stage))
        if showsSetupPhases { beginSetupPhase(steps.phase(stage)) }
      case let .succeed(stage):
        mutateSetupPhase(id: EphemeralSetupSteps.phaseId(stage)) { $0.succeed() }
      }
    }
  }

  private func failEphemeralStage(_ stage: EphemeralSetupStage?, message: String, showsSetupPhases: Bool) {
    guard showsSetupPhases, let stage else { return }
    mutateSetupPhase(id: EphemeralSetupSteps.phaseId(stage)) { $0.fail(message: message) }
  }

  private func adoptEphemeralMachine(_ machine: ServerEphemeralMachine, target: EphemeralTarget) async throws {
    guard let deviceId = machine.deviceId, let remoteProjectId = machine.remoteProjectId, let machines else {
      throw EphemeralMachineSetupError(message: "The \(target.machineNoun) didn't report where its project is")
    }
    let machineId = CodevisorMachine.cloudIdPrefix + deviceId
    status = .connecting("Connecting to \(target.machineNoun)…")
    let (remote, client) = try await reachProject(
      remoteProjectId, on: machineId, machines: machines, target: target)
    let agent = currentComposerSelectionIntent()
    relocateSession(to: remote)
    ephemeralTarget = nil
    await retarget(to: remote, serverClient: client)
    try await restoreAgent(agent, target: target)
  }

  private func restoreAgent(_ agent: ComposerSelectionIntent?, target: EphemeralTarget) async throws {
    guard let agent else { return }
    let deadline = ContinuousClock.now + .seconds(120)
    while !harnesses.contains(where: { $0.id == agent.harnessId }) {
      guard ContinuousClock.now < deadline else {
        throw EphemeralMachineSetupError(message: "The chosen agent isn't ready on the \(target.machineNoun)")
      }
      try await Task.sleep(for: .seconds(1))
      await refreshHarnessCapabilities()
    }
    clearAutomaticSelection()
    selectedHarnessId = agent.harnessId
    pendingConfiguration.replaceValues(carriedConfigValues(agent), for: agent.harnessId)
  }

  private func carriedConfigValues(_ agent: ComposerSelectionIntent) -> [String: String] {
    let options = configOptionsByHarness[agent.harnessId] ?? []
    var values = agent.compatibleConfigValues(in: options)
    guard let modelValue = agent.modelValue, let model = Self.modelOption(in: options),
      model.options.contains(where: { $0.value == modelValue })
    else { return values }
    values[model.id] = modelValue
    return values
  }

  private func reachProject(
    _ remoteProjectId: String,
    on machineId: String,
    machines: MachineController,
    target: EphemeralTarget
  ) async throws -> (Project, any CodevisorServerClienting) {
    let deadline = ContinuousClock.now + .seconds(180)
    while true {
      try await waitUntilReachable(machineId, machines: machines, target: target, deadline: deadline)
      let client = machines.client(for: machineId)
      do {
        return (try await remoteProject(remoteProjectId, client: client, machineId: machineId), client)
      } catch let error as EphemeralMachineSetupError {
        throw error
      } catch {
        guard ContinuousClock.now < deadline else { throw error }
        await machines.cloudProvider?.refreshCloudMachines()
        try await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func waitUntilReachable(
    _ machineId: String,
    machines: MachineController,
    target: EphemeralTarget,
    deadline: ContinuousClock.Instant
  ) async throws {
    var attempt = 0
    while machines.availability(for: machineId) != .ready {
      guard ContinuousClock.now < deadline else {
        throw EphemeralMachineSetupError(message: "Couldn't connect to the \(target.machineNoun)")
      }
      await reachMachine(machineId, machines: machines, refreshesRoster: attempt % 5 == 0)
      attempt += 1
      guard machines.availability(for: machineId) != .ready else { return }
      try await Task.sleep(for: .seconds(1))
    }
  }

  private func reachMachine(_ machineId: String, machines: MachineController, refreshesRoster: Bool) async {
    if refreshesRoster { await machines.cloudProvider?.refreshCloudMachines() }
    guard machines.machine(for: machineId) != nil else { return }
    await machines.prepareMachine(machineId)
  }

  private func remoteProject(
    _ projectId: String,
    client: any CodevisorServerClienting,
    machineId: String
  ) async throws -> Project {
    let projects = try await client.listProjects()
    guard let match = projects.first(where: { $0.id.lowercased() == projectId.lowercased() }) else {
      throw EphemeralMachineSetupError(message: "The cloned project isn't on the ephemeral machine")
    }
    return try match.project(serverId: machineId)
  }

  private func relocateSession(to remote: Project) {
    guard let previous = serverSession else { return }
    var relocated = previous
    relocated.serverId = remote.serverId
    relocated.projectId = remote.id
    relocated.harnessId = ""
    serverSession = relocated
    onEphemeralMachineReady?(previous, relocated, remote)
  }
}

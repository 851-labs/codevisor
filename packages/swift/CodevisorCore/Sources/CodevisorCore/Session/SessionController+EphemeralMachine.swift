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
    let machineId = UUID().uuidString.lowercased()
    let tracker = EphemeralSetupTracker(
      controller: self, steps: ephemeralSteps(for: target), showsPhases: showsSetupPhases)
    status = .connecting(tracker.steps.status(.create))
    let follow = followEphemeralLog(machineId, client: serverClient, tracker: tracker)
    defer { follow.cancel() }
    do {
      _ = try await serverClient.createEphemeralMachine(
        id: machineId, provider: target.providerId, projectId: project.id, workspaceId: hostWorkspaceId)
      let ready = try await awaitEphemeralMachine(machineId, client: serverClient, tracker: tracker)
      try await adoptEphemeralMachine(ready, target: target, tracker: tracker)
      return nil
    } catch {
      try? await serverClient.destroyEphemeralMachine(id: machineId)
      return serverErrorMessage(error)
    }
  }

  private func ephemeralSteps(for target: EphemeralTarget) -> EphemeralSetupSteps {
    EphemeralSetupSteps(target: target, projectName: project.name, agentName: selectedHarness?.name ?? "the agent")
  }

  private func followEphemeralLog(
    _ machineId: String,
    client: any CodevisorServerClienting,
    tracker: EphemeralSetupTracker
  ) -> Task<Void, Never> {
    let log = EphemeralSetupLogLine.liveLog(client, machineId: machineId)
    return Task { [weak tracker] in
      for await line in log { tracker?.append(line) }
    }
  }

  private func awaitEphemeralMachine(
    _ id: String,
    client: any CodevisorServerClienting,
    tracker: EphemeralSetupTracker
  ) async throws -> ServerEphemeralMachine {
    let deadline = ContinuousClock.now + .seconds(30 * 60)
    while ContinuousClock.now < deadline {
      let machine = try await ephemeralMachine(id, client: client)
      if let failure = Self.ephemeralFailure(machine) {
        tracker.failCurrent(failure)
        throw EphemeralMachineSetupError(message: failure)
      }
      tracker.apply(machine)
      if machine.state == "ready" { return machine }
      try await Task.sleep(for: .seconds(1))
    }
    throw EphemeralMachineSetupError(message: "The \(tracker.steps.target.machineNoun) took too long to start")
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

  private func adoptEphemeralMachine(
    _ machine: ServerEphemeralMachine,
    target: EphemeralTarget,
    tracker: EphemeralSetupTracker
  ) async throws {
    guard let deviceId = machine.deviceId, let remoteProjectId = machine.remoteProjectId, let machines else {
      throw EphemeralMachineSetupError(message: "The \(target.machineNoun) didn't report where its project is")
    }
    tracker.begin(.connect)
    let (remote, client) = try await reachProject(
      remoteProjectId, on: CodevisorMachine.cloudIdPrefix + deviceId, machines: machines, target: target)
    tracker.succeed(.connect)
    let agent = currentComposerSelectionIntent()
    relocateSession(to: remote)
    ephemeralTarget = nil
    tracker.begin(.agent)
    await retarget(to: remote, serverClient: client)
    try await restoreAgent(agent, target: target, tracker: tracker)
    tracker.succeed(.agent)
  }

  private func restoreAgent(
    _ agent: ComposerSelectionIntent?,
    target: EphemeralTarget,
    tracker: EphemeralSetupTracker
  ) async throws {
    guard let agent else { return }
    let deadline = ContinuousClock.now + .seconds(180)
    var lastDetail: String?
    while !harnesses.contains(where: { $0.id == agent.harnessId }) {
      guard ContinuousClock.now < deadline else {
        throw EphemeralMachineSetupError(message: "The chosen agent isn't ready on the \(target.machineNoun)")
      }
      let probe = await agentCapability(agent.harnessId)
      if let capability = probe.ready {
        adoptHarnessCapability(capability)
        break
      }
      if let detail = probe.detail, detail != lastDetail {
        tracker.note(detail, in: .agent)
        lastDetail = detail
      }
      try await Task.sleep(for: .seconds(1))
    }
    tracker.note("\(tracker.steps.agentName) is ready", in: .agent)
    clearAutomaticSelection()
    selectedHarnessId = agent.harnessId
    pendingConfiguration.replaceValues(carriedConfigValues(agent), for: agent.harnessId)
  }

  private func agentCapability(_ harnessId: String) async -> (ready: ServerHarnessCapability?, detail: String?) {
    guard let serverClient,
      let response = try? await serverClient.capabilities(cwd: capabilityCwd, harnessId: harnessId),
      let capability = response.harnesses.first(where: { $0.harness.id == harnessId })
    else { return (nil, "Waiting for the agent list") }
    if capability.harness.enabled, capability.harness.isReady { return (capability, nil) }
    return (nil, Self.agentWaitingReason(capability.harness))
  }

  private static func agentWaitingReason(_ harness: ServerHarness) -> String {
    guard harness.isReady else {
      return "Waiting for \(harness.name) to install (\(harness.readiness.detail ?? harness.readiness.state))"
    }
    switch harness.auth?.resolvedState {
    case .unauthenticated, .expired: return "\(harness.name) isn't signed in on this machine"
    case .checking, nil: return "Checking \(harness.name)'s sign-in"
    default: return "\(harness.name) isn't enabled on this machine"
    }
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

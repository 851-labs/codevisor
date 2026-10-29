import Foundation

struct SandboxSetupError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

extension SessionController {
  func createRequestedSandbox(showsSetupPhases: Bool) async -> String? {
    guard let sandboxTarget else { return nil }
    return await sandboxFailure(sandboxTarget, showsSetupPhases: showsSetupPhases)
  }

  private func sandboxFailure(_ target: SandboxTarget, showsSetupPhases: Bool) async -> String? {
    if project.isScratch || project.isRunTargetPlaceholder {
      return "Choose a project to run on a \(target.machineNoun)."
    }
    return await startSandbox(target, showsSetupPhases: showsSetupPhases)
  }

  private func startSandbox(_ target: SandboxTarget, showsSetupPhases: Bool) async -> String? {
    guard let creator = sandboxClient(for: target) else {
      return unreachableHostMessage(for: target)
    }
    guard let prewarm = takeSandboxPrewarm(for: target, client: creator) else {
      return "Choose a project to run on a \(target.machineNoun)."
    }
    let tracker = SandboxSetupTracker(
      controller: self, steps: sandboxSteps(for: target), showsPhases: showsSetupPhases)
    status = .connecting(tracker.steps.status(.create))
    defer { prewarm.finish() }
    let client = prewarm.client
    do {
      try await prewarm.created()
      tracker.apply(try await sandbox(prewarm.machineId, client: client))
      prewarm.attach(tracker)
      let ready = try await awaitSandbox(prewarm.machineId, client: client, tracker: tracker)
      try await adoptSandbox(try await claimWorkspace(ready, client: client), target: target, tracker: tracker)
      return nil
    } catch {
      let message = serverErrorMessage(error)
      tracker.failCurrent(message)
      try? await client.destroySandbox(id: prewarm.machineId)
      return message
    }
  }

  private func unreachableHostMessage(for target: SandboxTarget) -> String {
    guard target.hostMachineId != nil else {
      return "Sandboxes need the Codevisor server. Start it and try again."
    }
    return "The Mac that runs \(target.profileName) isn't connected. Open Codevisor there and try again."
  }

  private func claimWorkspace(
    _ machine: ServerSandbox,
    client: any CodevisorServerClienting
  ) async throws -> ServerSandbox {
    guard machine.workspaceId == nil, let hostWorkspaceId else { return machine }
    return try await client.claimSandboxWorkspace(id: machine.id, workspaceId: hostWorkspaceId)
  }

  private func sandboxSteps(for target: SandboxTarget) -> SandboxSetupSteps {
    SandboxSetupSteps(target: target, projectName: project.name, agentName: selectedHarness?.name ?? "the agent")
  }

  private func awaitSandbox(
    _ id: String,
    client: any CodevisorServerClienting,
    tracker: SandboxSetupTracker
  ) async throws -> ServerSandbox {
    let deadline = ContinuousClock.now + .seconds(30 * 60)
    while ContinuousClock.now < deadline {
      let machine = try await sandbox(id, client: client)
      if let failure = Self.sandboxFailure(machine) {
        tracker.failCurrent(failure)
        throw SandboxSetupError(message: failure)
      }
      tracker.apply(machine)
      if machine.state == "ready" { return machine }
      try await Task.sleep(for: .seconds(1))
    }
    throw SandboxSetupError(message: "The \(tracker.steps.target.machineNoun) took too long to start")
  }

  private func sandbox(
    _ id: String,
    client: any CodevisorServerClienting
  ) async throws -> ServerSandbox {
    guard let machine = try await client.sandboxes().first(where: { $0.id == id }) else {
      throw SandboxSetupError(message: "The sandbox was removed before it was ready")
    }
    return machine
  }

  private static func sandboxFailure(_ machine: ServerSandbox) -> String? {
    switch machine.state {
    case "failed": machine.error ?? "The sandbox could not be set up"
    case "destroying": "The sandbox is being destroyed"
    default: nil
    }
  }

  private func adoptSandbox(
    _ machine: ServerSandbox,
    target: SandboxTarget,
    tracker: SandboxSetupTracker
  ) async throws {
    tracker.begin(.connect)
    guard let deviceId = machine.deviceId, let remoteProjectId = machine.remoteProjectId, let machines else {
      throw SandboxSetupError(message: "The \(target.machineNoun) didn't report where its project is")
    }
    let (remote, client) = try await reachProject(
      remoteProjectId, on: CodevisorMachine.cloudIdPrefix + deviceId, machines: machines, target: target)
    tracker.succeed(.connect)
    let agent = currentComposerSelectionIntent()
    relocateSession(to: remote)
    sandboxTarget = nil
    tracker.begin(.agent)
    handOff(to: remote, serverClient: client)
    try await restoreAgent(agent, target: target, tracker: tracker)
    tracker.succeed(.agent)
  }

  private func restoreAgent(
    _ agent: ComposerSelectionIntent?,
    target: SandboxTarget,
    tracker: SandboxSetupTracker
  ) async throws {
    guard let agent else { return }
    let deadline = ContinuousClock.now + .seconds(180)
    var lastDetail: String?
    while true {
      guard ContinuousClock.now < deadline else {
        throw SandboxSetupError(message: "The chosen agent isn't ready on the \(target.machineNoun)")
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
    target: SandboxTarget
  ) async throws -> (Project, any CodevisorServerClienting) {
    let deadline = ContinuousClock.now + .seconds(180)
    while true {
      try await waitUntilReachable(machineId, machines: machines, target: target, deadline: deadline)
      let client = machines.client(for: machineId)
      do {
        return (try await remoteProject(remoteProjectId, client: client, machineId: machineId), client)
      } catch let error as SandboxSetupError {
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
    target: SandboxTarget,
    deadline: ContinuousClock.Instant
  ) async throws {
    var attempt = 0
    while machines.availability(for: machineId) != .ready {
      guard ContinuousClock.now < deadline else {
        throw SandboxSetupError(message: "Couldn't connect to the \(target.machineNoun)")
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
      throw SandboxSetupError(message: "The cloned project isn't on the sandbox")
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
    onSandboxReady?(previous, relocated, remote)
  }
}

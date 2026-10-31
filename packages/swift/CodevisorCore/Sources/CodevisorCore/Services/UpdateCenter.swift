import Foundation
import Observation

@MainActor
@Observable
public final class UpdateCenter {
  @ObservationIgnored public var listedHarnessIds: (@MainActor () -> Set<String>?)?
  private let machines: MachineController
  private let appUpdate: AppUpdateModel
  private let store: (any PersistenceStore)?
  private static let sessionKey = "updateCenter.pendingSession"
  private let updateRunPollInterval: Duration
  private let updateRunPollAttempts: Int

  public private(set) var isRefreshing = false
  public private(set) var isCheckingForUpdates = false
  private var hasDeferredRefresh = false
  private var refreshTask: Task<Void, Never>?
  private var refreshTaskIsForced = false
  public private(set) var isUpdatingAll = false
  public private(set) var lastRefreshedAt: Date?
  @ObservationIgnored private let now: @MainActor () -> Date
  public internal(set) var updateAllNotice: String?
  private var harnessesByMachine: [String: [ServerHarness]] = [:]
  var transientPhases: [String: UpdateComponent.Phase] = [:]
  private var dismissedHarnessFailures: [String: ServerHarnessLifecycleState] = [:]

  public init(
    machines: MachineController,
    appUpdate: AppUpdateModel,
    store: (any PersistenceStore)? = nil,
    updateRunPollInterval: Duration = .seconds(3),
    updateRunPollAttempts: Int = 1_200,
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.now = now
    self.machines = machines
    self.appUpdate = appUpdate
    self.store = store ?? machines.persistenceStore
    self.updateRunPollInterval = updateRunPollInterval
    self.updateRunPollAttempts = updateRunPollAttempts
  }

  public var components: [UpdateComponent] {
    appComponents + serverComponents + harnessComponents
  }

  public var availableCount: Int {
    components.count(where: \.updateAvailable)
  }

  public var machineGroups: [UpdateMachineGroup] {
    let byMachine = Dictionary(grouping: components, by: \.machineId)
    return machines.allMachines.compactMap { machine in
      guard let rows = byMachine[machine.id], !rows.isEmpty else { return nil }
      return UpdateMachineGroup(
        id: machine.id,
        machineName: machine.name,
        codevisor: rows.first { $0.kind == .app || $0.kind == .server },
        components: rows.filter { $0.kind == .harness }
      )
    }
  }

  private var appComponents: [UpdateComponent] {
    guard appUpdate.checkHandler != nil else { return [] }
    let release = appUpdate.availableRelease
    let phase: UpdateComponent.Phase =
      switch appUpdate.phase {
      case .updating: .updating
      case let .failed(_, message): .failed(message)
      case .idle, .checking, .upToDate, .available: .idle
      }
    return [
      UpdateComponent(
        id: "app",
        kind: .app,
        machineId: CodevisorMachine.local.id,
        machineName: machineName(for: CodevisorMachine.local.id),
        subjectId: "",
        title: "Codevisor",
        installedVersion: appUpdate.displayedCurrentVersion,
        latestVersion: release?.version,
        updateAvailable: release != nil,
        phase: phase,
        statusMessage: phase == .updating ? appUpdate.statusMessage : nil,
        progress: phase == .updating ? appUpdate.progress : nil
      )
    ]
  }

  private var serverComponents: [UpdateComponent] {
    machines.allMachines.compactMap { machine in
      if machine.isLocal { return nil }
      guard let connection = machines.connectionsById[machine.id],
        connection.updateInfo != nil || connection.dataUpgradeProgress != nil
      else { return nil }
      return UpdateComponent.server(machine: machine, connection: connection)
    }
  }

  private var orderedMachineIds: [String] {
    machines.allMachines.map(\.id)
  }

  private var harnessComponents: [UpdateComponent] {
    let listed = listedHarnessIds?()
    return orderedMachineIds.flatMap { machineId in
      (harnessesByMachine[machineId] ?? []).compactMap { harness -> UpdateComponent? in
        harnessComponent(harness, machineId: machineId, listed: listed)
      }
    }
  }

  private func harnessComponent(_ harness: ServerHarness, machineId: String, listed: Set<String>?) -> UpdateComponent? {
    if let listed, !listed.contains(harness.id) { return nil }
    let status = harnessStatus(harness, machineId: machineId)
    let available = harness.updateInfo?.updateAvailable == true
    guard available || status.isActive else { return nil }
    let id = "harness:\(machineId):\(harness.id)"
    let phase = harnessPhase(harness, id: id, status: status)
    return UpdateComponent(
      id: id,
      kind: .harness,
      machineId: machineId,
      machineName: machineName(for: machineId),
      subjectId: harness.id,
      title: harness.name,
      installedVersion: harness.updateInfo?.installedVersion,
      latestVersion: harness.updateInfo?.latestVersion,
      updateAvailable: available,
      phase: phase,
      statusMessage: status.message,
      notes: harness.updateInfo?.notes,
      canCancel: status.canCancel
    )
  }

  private func harnessStatus(_ harness: ServerHarness, machineId: String) -> HarnessUpdateStatus {
    let connection = machines.connectionsById[machineId]
    return HarnessUpdateStatus.of(
      harness,
      run: connection?.updateRun,
      pauseIsHarnessScoped: connection?.restartDrain?.harnessIds != nil
    )
  }

  private func harnessPhase(_ harness: ServerHarness, id: String, status: HarnessUpdateStatus) -> UpdateComponent.Phase
  {
    if harness.lifecycle?.phase == "failed" { return failedHarnessPhase(harness, id: id) }
    if status.isActive { return .updating }
    return transientPhases[id] ?? .idle
  }

  private func failedHarnessPhase(_ harness: ServerHarness, id: String) -> UpdateComponent.Phase {
    if let phase = transientPhases[id] { return phase }
    if dismissedHarnessFailures[id] == harness.lifecycle { return .idle }
    return .failed(harness.lifecycle?.error ?? "The update failed.")
  }

  private func machineName(for machineId: String) -> String {
    machines.machine(for: machineId)?.name ?? machineId
  }

  private func resetFailures() -> [String] {
    var retryMachines: [String] = []
    updateAllNotice = nil
    transientPhases = transientPhases.filter { $0.value == .updating }
    for (machineId, harnesses) in harnessesByMachine {
      for harness in harnesses where harness.lifecycle?.phase == "failed" {
        dismissedHarnessFailures["harness:\(machineId):\(harness.id)"] = harness.lifecycle
      }
    }
    for connection in machines.connectionsById.values where connection.updatePhase != .updating {
      if case .failed = connection.updatePhase, case .failed = connection.availability {
        retryMachines.append(connection.machineId)
      }
      connection.updatePhase = .idle
      connection.updateStatusMessage = nil
      connection.updateProgress = nil
    }
    appUpdate.resetFailure()
    return retryMachines
  }

  public func refresh(force: Bool = false) async {
    if force { isCheckingForUpdates = true }
    while let running = refreshTask {
      let coversRequest = refreshTaskIsForced || !force
      await running.value
      if coversRequest { return }
    }
    let task = Task { await self.performRefresh(force: force) }
    refreshTask = task
    refreshTaskIsForced = force
    isRefreshing = true
    await task.value
  }

  private func performRefresh(force: Bool) async {
    defer {
      refreshTask = nil
      refreshTaskIsForced = false
      isRefreshing = false
      if force { isCheckingForUpdates = false }
    }
    let retryMachines = force ? resetFailures() : []
    let unprobed = machines.allMachines.map(\.id).filter { machines.connectionsById[$0]?.status == nil }
    await withTaskGroup(of: Void.self) { group in
      for machineId in retryMachines {
        group.addTask { await self.machines.retryMachine(machineId) }
      }
      for machineId in unprobed where !retryMachines.contains(machineId) {
        group.addTask { await self.machines.refreshStatus(for: machineId) }
      }
    }
    if force {
      await appUpdate.checkForUpdates()
    } else {
      await appUpdate.checkForUpdatesInBackground()
    }
    await machines.refreshServerUpdates(force: force)
    let listed = listedHarnessIds?()
    for machine in machines.allMachines {
      guard machines.connectionsById[machine.id]?.status?.isReachable == true else {
        continue
      }
      let client = machines.client(for: machine.id)
      let harnesses: [ServerHarness]?
      if force, listed?.isEmpty != true {
        harnesses = try? await client.checkHarnessUpdates(harnessIds: listed.map { $0.sorted() })
      } else {
        harnesses = try? await client.listHarnessesWithLifecycle()
      }
      if let harnesses {
        harnessesByMachine[machine.id] = harnesses
      }
    }
    lastRefreshedAt = now()
  }

  public var hasUpdateInFlight: Bool {
    isUpdatingAll || components.contains { $0.phase == .updating }
  }

  public func backgroundRefresh() async {
    guard !hasUpdateInFlight else {
      hasDeferredRefresh = true
      return
    }
    hasDeferredRefresh = false
    await refresh()
  }

  private func runDeferredRefreshIfSettled() async {
    guard hasDeferredRefresh, !hasUpdateInFlight else { return }
    await backgroundRefresh()
  }

  public func noteHarnessLifecycleChanged(onServer serverId: String) {
    Task {
      await self.refreshHarnesses(onMachine: serverId)
      await self.runDeferredRefreshIfSettled()
    }
  }

  public func update(_ component: UpdateComponent) async {
    await install(component)
    await runDeferredRefreshIfSettled()
  }

  func install(_ component: UpdateComponent) async {
    switch component.kind {
    case .app:
      await appUpdate.installUpdate()
    case .server:
      await machines.updateServer(machineId: component.machineId)
    case .harness:
      dismissedHarnessFailures[component.id] = nil
      transientPhases[component.id] = .updating
      do {
        let started = try await machines.client(for: component.machineId)
          .updateHarness(id: component.subjectId)
        if let lifecycle = started.lifecycle {
          adoptHarnessLifecycle(lifecycle, harnessId: component.subjectId, onMachine: component.machineId)
        }
        await refreshHarnesses(onMachine: component.machineId)
        transientPhases[component.id] = nil
      } catch {
        transientPhases[component.id] = .failed(serverErrorMessage(error))
      }
    }
  }

  public func updateAll() async {
    while let running = refreshTask { await running.value }
    await run(components: components.filter { $0.updateAvailable && $0.notes == nil })
    await runDeferredRefreshIfSettled()
  }

  public func cancel(_ component: UpdateComponent) async {
    guard component.canCancel else { return }

    let client = machines.client(for: component.machineId)
    if let run = try? await client.cancelUpdateRun() {
      machines.connection(for: component.machineId).updateRun = run
    }
    await refreshHarnesses(onMachine: component.machineId)
  }

  private func run(components snapshot: [UpdateComponent]) async {
    guard !isUpdatingAll, !snapshot.isEmpty else { return }
    isUpdatingAll = true
    updateAllNotice = nil
    defer { isUpdatingAll = false }
    let run = UpdateAllRun(
      center: self,
      machines: machines,
      snapshot: snapshot,
      pollInterval: updateRunPollInterval,
      pollAttempts: updateRunPollAttempts
    )
    await run.perform()
  }

  public func resumePendingSessionIfNeeded() async {
    guard let remaining = loadSession() else { return }
    await refresh(force: true)
    let pending = components.filter { remaining.contains($0.id) && $0.updateAvailable }
    if pending.isEmpty {
      clearSession()
    } else {
      await run(components: pending)
      await runDeferredRefreshIfSettled()
    }
  }
}

extension UpdateCenter {
  func refreshHarnesses(onMachine machineId: String) async {
    guard
      let harnesses = try? await machines.client(for: machineId)
        .listHarnessesWithLifecycle()
    else { return }
    harnessesByMachine[machineId] = harnesses
  }

  private func adoptHarnessLifecycle(
    _ lifecycle: ServerHarnessLifecycleState,
    harnessId: String,
    onMachine machineId: String
  ) {
    guard var harnesses = harnessesByMachine[machineId],
      let index = harnesses.firstIndex(where: { $0.id == harnessId })
    else { return }
    harnesses[index].lifecycle = lifecycle
    harnessesByMachine[machineId] = harnesses
  }

  func persistSession(_ remaining: Set<String>) {
    guard let store else { return }
    try? store.saveData(JSONEncoder().encode(remaining.sorted()), forKey: Self.sessionKey)
  }

  private func loadSession() -> Set<String>? {
    guard let store, let data = store.loadData(forKey: Self.sessionKey),
      let ids = try? JSONDecoder().decode([String].self, from: data)
    else { return nil }
    return Set(ids)
  }

  func clearSession() {
    try? store?.removeData(forKey: Self.sessionKey)
  }
}

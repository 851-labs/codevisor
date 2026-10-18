import Foundation
import Observation

@MainActor
@Observable
public final class UpdateCenter {
  @ObservationIgnored public var reviewPluginUpdate: (@MainActor (String, ServerPluginUpdatePlan) async throws -> Void)?
  @ObservationIgnored public var listedHarnessIds: (@MainActor () -> Set<String>?)?
  private let machines: MachineController
  private let appUpdate: AppUpdateModel
  private let store: (any PersistenceStore)?
  private static let sessionKey = "updateCenter.pendingSession"
  private let harnessSettlePollInterval: Duration
  private let harnessSettleAttempts: Int

  public private(set) var isRefreshing = false
  public private(set) var isCheckingForUpdates = false
  private var hasDeferredRefresh = false
  private var refreshTask: Task<Void, Never>?
  private var refreshTaskIsForced = false
  public private(set) var isUpdatingAll = false
  public private(set) var lastRefreshedAt: Date?
  public private(set) var updateAllNotice: String?
  private var harnessesByMachine: [String: [ServerHarness]] = [:]
  private var pluginUpdatesByMachine: [String: [ServerPluginUpdateStatus]] = [:]
  private var transientPhases: [String: UpdateComponent.Phase] = [:]
  private var dismissedHarnessFailures: [String: ServerHarnessLifecycleState] = [:]

  public init(
    machines: MachineController,
    appUpdate: AppUpdateModel,
    store: (any PersistenceStore)? = nil,
    harnessSettlePollInterval: Duration = .seconds(3),
    harnessSettleAttempts: Int = 300
  ) {
    self.machines = machines
    self.appUpdate = appUpdate
    self.store = store ?? machines.persistenceStore
    self.harnessSettlePollInterval = harnessSettlePollInterval
    self.harnessSettleAttempts = harnessSettleAttempts
  }

  public var components: [UpdateComponent] {
    appComponents + serverComponents + harnessComponents + pluginComponents
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
        isLocal: machine.isLocal,
        codevisor: rows.first { $0.kind == .app || $0.kind == .server },
        components: [.harness, .plugin].flatMap { kind in rows.filter { $0.kind == kind } }
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
    let lifecycleActive = Self.harnessLifecycleIsActive(harness)
    let available = harness.updateInfo?.updateAvailable == true
    guard available || lifecycleActive else { return nil }
    let id = "harness:\(machineId):\(harness.id)"
    let lifecyclePhase = harness.lifecycle?.phase
    let phase = harnessPhase(harness, id: id, lifecyclePhase: lifecyclePhase)
    let statusMessage = UpdateComponent.harnessStatusMessage(harness, lifecyclePhase: lifecyclePhase)
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
      statusMessage: statusMessage,
      notes: harness.updateInfo?.notes
    )
  }

  private func harnessPhase(_ harness: ServerHarness, id: String, lifecyclePhase: String?) -> UpdateComponent.Phase {
    switch lifecyclePhase {
    case "installing", "updating", "pendingUpdate": return .updating
    case "failed":
      if let phase = transientPhases[id] { return phase }
      if dismissedHarnessFailures[id] == harness.lifecycle { return .idle }
      return .failed(harness.lifecycle?.error ?? "The update failed.")
    default: return transientPhases[id] ?? .idle
    }
  }

  private static func harnessLifecycleIsActive(_ harness: ServerHarness) -> Bool {
    ["installing", "updating", "pendingUpdate"].contains(harness.lifecycle?.phase ?? "")
  }

  private var pluginComponents: [UpdateComponent] {
    orderedMachineIds.flatMap { machineId in
      (pluginUpdatesByMachine[machineId] ?? []).compactMap { status -> UpdateComponent? in
        let id = "plugin:\(machineId):\(status.pluginId)"
        let phase = transientPhases[id] ?? .idle
        guard status.state == .available || phase != .idle else { return nil }
        return UpdateComponent(
          id: id,
          kind: .plugin,
          machineId: machineId,
          machineName: machineName(for: machineId),
          subjectId: status.pluginId,
          title: status.pluginId,
          installedVersion: status.installedVersion,
          latestVersion: status.registryVersion,
          updateAvailable: status.state == .available,
          phase: phase
        )
      }
    }
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
      if let plugins = try? await client.listPluginUpdates() {
        pluginUpdatesByMachine[machine.id] = plugins
      }
    }
    lastRefreshedAt = Date()
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

  private func install(_ component: UpdateComponent) async {
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
    case .plugin:
      transientPhases[component.id] = .updating
      do {
        let client = machines.client(for: component.machineId)
        let plan = try await client.preparePluginUpdate(pluginId: component.subjectId)
        try await reviewPluginUpdate?(component.machineId, plan)
        _ = try await client.applyPluginUpdate(
          pluginId: component.subjectId,
          planId: plan.planId
        )
        transientPhases[component.id] = nil
        await refreshPlugins(onMachine: component.machineId)
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

  private func run(components snapshot: [UpdateComponent]) async {
    guard !isUpdatingAll, !snapshot.isEmpty else { return }
    isUpdatingAll = true
    updateAllNotice = nil
    defer { isUpdatingAll = false }
    var remaining = Set(snapshot.map(\.id))
    persistSession(remaining)
    let harnessMachines = Set(snapshot.filter { $0.kind == .harness }.map(\.machineId))
    for kind in [UpdateComponent.Kind.plugin, .harness, .server, .app] {
      if kind == .app {
        for machineId in harnessMachines.sorted() {
          await waitForHarnessUpdatesToSettle(onMachine: machineId)
        }
        if let failure = firstFailure(in: snapshot) {
          updateAllNotice =
            "Codevisor was not restarted because \(failure.title) on \(failure.machineName) failed to update. Fix that, then update again."
          clearSession()
          return
        }
      }
      for component in snapshot where component.kind == kind {
        if kind == .server, harnessMachines.contains(component.machineId) {
          await waitForHarnessUpdatesToSettle(onMachine: component.machineId)
        }
        await install(component)
        remaining.remove(component.id)
        persistSession(remaining)
      }
    }
    if !snapshot.contains(where: { $0.kind == .app }) {
      clearSession()
    }
  }

  private func firstFailure(in snapshot: [UpdateComponent]) -> UpdateComponent? {
    let ids = Set(snapshot.map(\.id))
    return components.first { component in
      guard ids.contains(component.id), component.kind != .app, component.kind != .harness else { return false }
      if case .failed = component.phase { return true }
      return false
    }
  }

  private func waitForHarnessUpdatesToSettle(onMachine machineId: String) async {
    for attempt in 0..<harnessSettleAttempts {
      if attempt > 0 {
        try? await machines.updateScheduler.sleep(harnessSettlePollInterval)
      }
      await refreshHarnesses(onMachine: machineId)
      let active = (harnessesByMachine[machineId] ?? []).contains(where: Self.harnessLifecycleIsActive)
      if !active { return }
    }
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
  private func refreshHarnesses(onMachine machineId: String) async {
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

  private func refreshPlugins(onMachine machineId: String) async {
    guard let plugins = try? await machines.client(for: machineId).listPluginUpdates()
    else { return }
    pluginUpdatesByMachine[machineId] = plugins
  }

  private func persistSession(_ remaining: Set<String>) {
    guard let store else { return }
    try? store.saveData(JSONEncoder().encode(remaining.sorted()), forKey: Self.sessionKey)
  }

  private func loadSession() -> Set<String>? {
    guard let store, let data = store.loadData(forKey: Self.sessionKey),
      let ids = try? JSONDecoder().decode([String].self, from: data)
    else { return nil }
    return Set(ids)
  }

  private func clearSession() {
    try? store?.removeData(forKey: Self.sessionKey)
  }
}

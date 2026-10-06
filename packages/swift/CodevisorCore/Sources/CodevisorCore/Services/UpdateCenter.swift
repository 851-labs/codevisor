import Foundation
import Observation

/// The fleet-wide update fold: app + every machine's server, harnesses, and
/// plugins, as one observable component list with per-row actions and a
/// properly ordered "update all". Server rows read live per-connection
/// state (updated by polls and `update.changed` events); harness and plugin
/// inventories are swept on `refresh` and re-fetched when lifecycle events
/// arrive.
///
/// The Updates pane shows whatever the last sweep found — the same list the
/// ambient count is built from — and never blocks on a fresh check. While
/// anything is installing, the periodic sweep holds off (see
/// `backgroundRefresh`), so the list the user is acting on stays put.
@MainActor
@Observable
public final class UpdateCenter {
  @ObservationIgnored public var reviewPluginUpdate: (@MainActor (String, ServerPluginUpdatePlan) async throws -> Void)?
  /// The ids in the shared harness list (Settings › Harnesses). Only those
  /// harnesses are checked and shown; a harness the user never added is not
  /// theirs to update. Nil — no provider, or the list has not synced yet —
  /// means unknown, and every harness is considered.
  @ObservationIgnored public var listedHarnessIds: (@MainActor () -> Set<String>?)?
  private let machines: MachineController
  private let appUpdate: AppUpdateModel
  /// Durable home of the update-all session, so a run interrupted by the
  /// app's own restart (its legitimate final step) or a crash resumes on
  /// the next launch. Nil in previews/tests without persistence.
  private let store: (any PersistenceStore)?
  private static let sessionKey = "updateCenter.pendingSession"
  /// How often update-all re-reads a machine's harness inventory while
  /// waiting for its in-flight harness updates to settle, and for how long.
  private let harnessSettlePollInterval: Duration
  private let harnessSettleAttempts: Int

  /// A sweep (periodic or forced) is running. The Updates pane shows it in
  /// its "Check Again" button and keeps the current list on screen.
  public private(set) var isRefreshing = false
  /// A forced check — every release feed asked afresh — was requested and
  /// has not finished (it may still be waiting for a plain sweep to end).
  /// Update-all waits for it rather than install from the list it replaces.
  public private(set) var isCheckingForUpdates = false
  /// A periodic sweep came due while something was installing and was held
  /// back; it runs as soon as the fleet settles.
  private var hasDeferredRefresh = false
  /// The one refresh in flight; later callers join it instead of racing it.
  private var refreshTask: Task<Void, Never>?
  private var refreshTaskIsForced = false
  public private(set) var isUpdatingAll = false
  public private(set) var lastRefreshedAt: Date?
  /// Why the last update-all stopped short (a step failed, so the app
  /// restart was skipped). Cleared when the next run starts.
  public private(set) var updateAllNotice: String?
  private var harnessesByMachine: [String: [ServerHarness]] = [:]
  private var pluginUpdatesByMachine: [String: [ServerPluginUpdateStatus]] = [:]
  /// Operation state for rows whose progress isn't streamed back into
  /// machine state (plugin updates; the harness trigger round-trip before
  /// lifecycle events take over).
  private var transientPhases: [String: UpdateComponent.Phase] = [:]
  /// Older servers retain failed lifecycle reports after a fresh check.
  /// Dismiss that exact attempt until it changes or the user retries it.
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
    // Defaults to the machine controller's store, so production always
    // persists without extra wiring; tests may inject their own.
    self.store = store ?? machines.persistenceStore
    self.harnessSettlePollInterval = harnessSettlePollInterval
    self.harnessSettleAttempts = harnessSettleAttempts
  }

  // MARK: - Components

  public var components: [UpdateComponent] {
    appComponents + serverComponents + harnessComponents + pluginComponents
  }

  /// How many components currently have an update to install — the number
  /// behind every ambient indicator.
  public var availableCount: Int {
    components.count(where: \.updateAvailable)
  }

  /// Components grouped per machine in the fleet's machine order: the
  /// machine's Codevisor (app or server) split out, then its harnesses and
  /// plugins. Machines with nothing to show (no known Codevisor, nothing
  /// updatable) are omitted.
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
    // No check handler means no self-updater on this platform (iOS App
    // Store builds, development runs) — the app is not a component here.
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
      // The local machine's server ships inside the app bundle; its
      // update IS the app update row above. Builds without a self-updater
      // (development) update the local server by rebuilding, never here.
      if machine.isLocal { return nil }
      // A machine booting through a data upgrade has a row even before
      // this client ever read its release state: the migration IS the
      // update in progress, whoever asked for it.
      guard let connection = machines.connectionsById[machine.id],
        connection.updateInfo != nil || connection.dataUpgradeProgress != nil
      else { return nil }
      let info = connection.updateInfo
      let migration = connection.updatePhase == .idle ? connection.dataUpgradeProgress : nil
      let phase: UpdateComponent.Phase =
        switch connection.updatePhase {
        case .idle:
          if let migration {
            migration.error.map(UpdateComponent.Phase.failed) ?? .updating
          } else {
            .idle
          }
        case .updating: .updating
        case let .failed(message): .failed(message)
        }
      return UpdateComponent(
        id: "server:\(machine.id)",
        kind: .server,
        machineId: machine.id,
        machineName: machine.name,
        subjectId: "",
        // The machine's Codevisor, whatever form it takes there.
        title: "Codevisor",
        installedVersion: info.map {
          AppUpdateModel.displayedVersion(
            $0.currentVersion,
            buildNumber: $0.currentBuildNumber,
            usesAlphaChannel: $0.channel == "alpha"
          )
        },
        latestVersion: info?.latestVersion,
        updateAvailable: info?.updateAvailable ?? false,
        phase: phase,
        statusMessage: phase == .updating ? (migration?.name ?? connection.updateStatusMessage) : nil,
        progress: phase == .updating ? (migration?.fractionCompleted ?? connection.updateProgress) : nil
      )
    }
  }

  /// Machine ids in a stable, name-ordered sequence, so update-all and the
  /// rows it drives never depend on dictionary iteration order.
  private var orderedMachineIds: [String] {
    machines.allMachines.map(\.id)
  }

  private var harnessComponents: [UpdateComponent] {
    let listed = listedHarnessIds?()
    return orderedMachineIds.flatMap { machineId in
      (harnessesByMachine[machineId] ?? []).compactMap { harness -> UpdateComponent? in
        if let listed, !listed.contains(harness.id) { return nil }
        let lifecycleActive = Self.harnessLifecycleIsActive(harness)
        let available = harness.updateInfo?.updateAvailable == true
        guard available || lifecycleActive else { return nil }
        let id = "harness:\(machineId):\(harness.id)"
        let lifecyclePhase = harness.lifecycle?.phase
        // An armed update ("pendingUpdate") is in flight from the user's point
        // of view: the machine runs it as soon as the harness's live chats
        // end, the same drain a server update performs.
        let phase: UpdateComponent.Phase =
          switch lifecyclePhase {
          case "installing", "updating", "pendingUpdate": .updating
          case "failed":
            transientPhases[id]
              ?? (dismissedHarnessFailures[id] == harness.lifecycle
                ? .idle : .failed(harness.lifecycle?.error ?? "The update failed."))
          default: transientPhases[id] ?? .idle
          }
        let statusMessage: String? =
          switch lifecyclePhase {
          case "pendingUpdate": "Waiting for chats to finish…"
          case "installing", "updating":
            harness.lifecycle?.targetVersion.map { "Updating to \($0)…" } ?? "Updating…"
          default: nil
          }
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

  // MARK: - Refresh

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

  /// Sweeps every reachable machine's harness and plugin inventories and
  /// every machine's Codevisor release state, this app's included. `force`
  /// (the explicit "Check for Updates" action) additionally makes every
  /// server bypass its cached release state; the plain sweep reads what
  /// the servers already know.
  ///
  /// One refresh runs at a time. A caller arriving mid-refresh waits for
  /// it; a forced caller that finds only a plain sweep running then runs
  /// its own check, so "Check Again" pressed during the periodic sweep
  /// still asks every feed afresh.
  public func refresh(force: Bool = false) async {
    if force { isCheckingForUpdates = true }
    while let running = refreshTask {
      let coversRequest = refreshTaskIsForced || !force
      await running.value
      if coversRequest { return }
    }
    // The task clears this state itself when it ends, so every waiter sees
    // it gone the moment the refresh's value arrives.
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
    // A machine that has never been probed is unknown, not unreachable.
    // Probe those first, so the pane's first open — often seconds after
    // launch, ahead of the periodic status sweep — sees the whole fleet
    // instead of reporting "up to date" over an empty list.
    let unprobed = machines.allMachines.map(\.id).filter { machines.connectionsById[$0]?.status == nil }
    await withTaskGroup(of: Void.self) { group in
      for machineId in retryMachines {
        group.addTask { await self.machines.retryMachine(machineId) }
      }
      for machineId in unprobed where !retryMachines.contains(machineId) {
        group.addTask { await self.machines.refreshStatus(for: machineId) }
      }
    }
    // This app is checked on the same cadence as every other machine's
    // Codevisor: each sweep asks its feed, so a release shows up on the
    // local row when it shows up on the remote ones.
    if force {
      await appUpdate.checkForUpdates()
    } else {
      await appUpdate.checkForUpdatesInBackground()
    }
    // A plain sweep reads each server's cached release state; only a
    // forced check makes the servers ask their release origin.
    await machines.refreshServerUpdates(force: force)
    let listed = listedHarnessIds?()
    for machine in machines.allMachines {
      guard machines.connectionsById[machine.id]?.status?.isReachable == true else {
        continue
      }
      let client = machines.client(for: machine.id)
      let harnesses: [ServerHarness]?
      if force, listed?.isEmpty != true {
        // Only the listed harnesses are worth a feed lookup.
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

  /// Anything is installing right now: an update-all run, or any single
  /// row mid-update (including a harness update armed to run once its
  /// chats finish).
  public var hasUpdateInFlight: Bool {
    isUpdatingAll || components.contains { $0.phase == .updating }
  }

  /// The periodic sweep. Holds off while anything is installing — a sweep
  /// then would reshuffle the list the user is watching and acting on — and
  /// runs once the fleet settles instead. In-flight rows keep tracking their
  /// own progress through lifecycle events and per-row re-reads meanwhile.
  public func backgroundRefresh() async {
    guard !hasUpdateInFlight else {
      hasDeferredRefresh = true
      return
    }
    hasDeferredRefresh = false
    await refresh()
  }

  /// Runs the sweep held back by `backgroundRefresh` once nothing is
  /// installing any more.
  private func runDeferredRefreshIfSettled() async {
    guard hasDeferredRefresh, !hasUpdateInFlight else { return }
    await backgroundRefresh()
  }

  /// A machine's harness lifecycle changed (install/update progress, a
  /// finished update): re-read that machine's inventory so rows track it.
  public func noteHarnessLifecycleChanged(onServer serverId: String) {
    Task {
      await self.refreshHarnesses(onMachine: serverId)
      await self.runDeferredRefreshIfSettled()
    }
  }

  // MARK: - Actions

  /// Installs one component's update and waits for the outcome the row can
  /// observe (server convergence; harness trigger accepted; plugin
  /// prepared and applied; the app handed to its updater).
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
        // The row stays in progress from the click on. The acknowledgement
        // carries the state the server just installed; adopt it, then read
        // the inventory, and only then drop the local phase — clearing it
        // first let the row fall back to the stale "Update" button between
        // the two spinners.
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

  /// Installs every available update in dependency order: plugins and
  /// harnesses first (no restarts), then remote servers, and the app LAST
  /// — its update restarts this client, so everything it orchestrates must
  /// already be done.
  public func updateAll() async {
    // Never install from a list a running check is about to replace.
    while let running = refreshTask { await running.value }
    // A major-version update waits for its own confirmed click.
    await run(components: components.filter { $0.updateAvailable && $0.notes == nil })
    await runDeferredRefreshIfSettled()
  }

  /// Installs the given components in order, persisting the remaining ids
  /// before each step so an interrupted run can pick up where it stopped.
  ///
  /// Harness updates are only *triggered* by their step (the install runs
  /// on the machine), so before a machine's server restarts — and before
  /// the app restarts this client — the run waits for that machine's
  /// harness updates to settle. Failed harness updates remain visible but
  /// never prevent Codevisor from updating on that machine or this client.
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
    // An app component means Sparkle is restarting this client: leave
    // the (empty) session for the relaunched app to consume — finishing
    // the run there is the visible "it worked". Otherwise the run is
    // simply over.
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

  /// Polls a machine's harness inventory until none of its harnesses is
  /// installing, updating, or armed to update — or the wait budget runs
  /// out, in which case the run proceeds (the server re-arms interrupted
  /// harness updates after it restarts).
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

  /// Continues an update-all interrupted by the app's own restart (the
  /// normal final step) or a crash: refreshes, and installs whatever is
  /// both still pending and still updatable.
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

// MARK: - Inventory reads and session persistence

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

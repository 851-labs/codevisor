import Foundation
import Observation

/// One updatable thing somewhere in the fleet: the app itself, a machine's
/// server, or a harness/plugin on a machine. The row identity every update
/// surface (sheet, footer count, update-all) folds over.
public struct UpdateComponent: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case app
        case server
        case harness
        case plugin
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case updating
        case failed(String)
    }

    public let id: String
    public let kind: Kind
    public let machineId: String
    public let machineName: String
    /// The harness/plugin id on its machine; empty for app/server rows.
    public let subjectId: String
    public let title: String
    public let installedVersion: String?
    public let latestVersion: String?
    public let updateAvailable: Bool
    public let phase: Phase
}

/// The fleet-wide update fold: app + every machine's server, harnesses, and
/// plugins, as one observable component list with per-row actions and a
/// properly ordered "update all". Server rows read live per-connection
/// state (updated by polls and `update.changed` events); harness and plugin
/// inventories are swept on `refresh` and re-fetched when lifecycle events
/// arrive.
@MainActor
@Observable
public final class UpdateCenter {
    private let machines: MachineController
    private let appUpdate: AppUpdateModel
    /// Durable home of the update-all session, so a run interrupted by the
    /// app's own restart (its legitimate final step) or a crash resumes on
    /// the next launch. Nil in previews/tests without persistence.
    private let store: (any PersistenceStore)?
    private static let sessionKey = "updateCenter.pendingSession"

    /// Whether the update surface (sheet/screen) is open. Lives here so the
    /// menu item, sidebar footer, and settings entry all drive one flag.
    public var isPresented = false
    public private(set) var isRefreshing = false
    public private(set) var isUpdatingAll = false
    public private(set) var lastRefreshedAt: Date?
    private var harnessesByMachine: [String: [ServerHarness]] = [:]
    private var pluginUpdatesByMachine: [String: [ServerPluginUpdateStatus]] = [:]
    /// Operation state for rows whose progress isn't streamed back into
    /// machine state (plugin updates; the harness trigger round-trip before
    /// lifecycle events take over).
    private var transientPhases: [String: UpdateComponent.Phase] = [:]

    public init(
        machines: MachineController,
        appUpdate: AppUpdateModel,
        store: (any PersistenceStore)? = nil
    ) {
        self.machines = machines
        self.appUpdate = appUpdate
        // Defaults to the machine controller's store, so production always
        // persists without extra wiring; tests may inject their own.
        self.store = store ?? machines.persistenceStore
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
                installedVersion: appUpdate.currentVersion,
                latestVersion: release?.version,
                updateAvailable: release != nil,
                phase: phase
            )
        ]
    }

    private var serverComponents: [UpdateComponent] {
        machines.allMachines.compactMap { machine in
            // The local machine's server ships inside the app bundle; its
            // update IS the app update row above.
            if machine.isLocal, appUpdate.checkHandler != nil { return nil }
            guard let connection = machines.connectionsById[machine.id],
                let info = connection.updateInfo
            else { return nil }
            let phase: UpdateComponent.Phase =
                switch connection.updatePhase {
                case .idle: .idle
                case .updating: .updating
                case let .failed(message): .failed(message)
                }
            return UpdateComponent(
                id: "server:\(machine.id)",
                kind: .server,
                machineId: machine.id,
                machineName: machine.name,
                subjectId: "",
                title: "Codevisor Server",
                installedVersion: info.currentVersion,
                latestVersion: info.latestVersion,
                updateAvailable: info.updateAvailable,
                phase: phase
            )
        }
    }

    private var harnessComponents: [UpdateComponent] {
        harnessesByMachine.flatMap { machineId, harnesses in
            harnesses.compactMap { harness -> UpdateComponent? in
                let lifecycleActive = ["installing", "updating", "pendingUpdate"]
                    .contains(harness.lifecycle?.phase ?? "")
                let available = harness.updateInfo?.updateAvailable == true
                guard available || lifecycleActive else { return nil }
                let id = "harness:\(machineId):\(harness.id)"
                let phase: UpdateComponent.Phase =
                    switch harness.lifecycle?.phase {
                    case "installing", "updating": .updating
                    case "failed": .failed(harness.lifecycle?.error ?? "The update failed.")
                    default: transientPhases[id] ?? .idle
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
                    phase: phase
                )
            }
        }
    }

    private var pluginComponents: [UpdateComponent] {
        pluginUpdatesByMachine.flatMap { machineId, updates in
            updates.compactMap { status -> UpdateComponent? in
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

    /// Sweeps every reachable machine's harness and plugin inventories.
    /// `force` additionally re-checks the app and every server's release
    /// feeds (the explicit "Check for Updates" action); the plain sweep
    /// reads what the servers already know.
    public func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if force {
            await appUpdate.checkForUpdatesInBackground()
            await machines.refreshServerUpdates(force: true)
        }
        for machine in machines.allMachines {
            guard machines.connectionsById[machine.id]?.status?.isReachable == true else {
                continue
            }
            let client = machines.client(for: machine.id)
            let harnesses: [ServerHarness]?
            if force {
                harnesses = try? await client.checkHarnessUpdates()
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

    /// A machine's harness lifecycle changed (install/update progress, a
    /// finished update): re-read that machine's inventory so rows track it.
    public func noteHarnessLifecycleChanged(onServer serverId: String) {
        Task { await self.refreshHarnesses(onMachine: serverId) }
    }

    private func refreshHarnesses(onMachine machineId: String) async {
        guard
            let harnesses = try? await machines.client(for: machineId)
                .listHarnessesWithLifecycle()
        else { return }
        harnessesByMachine[machineId] = harnesses
    }

    private func refreshPlugins(onMachine machineId: String) async {
        guard let plugins = try? await machines.client(for: machineId).listPluginUpdates()
        else { return }
        pluginUpdatesByMachine[machineId] = plugins
    }

    // MARK: - Actions

    /// Installs one component's update and waits for the outcome the row can
    /// observe (server convergence; harness trigger accepted; plugin
    /// prepared and applied; the app handed to its updater).
    public func update(_ component: UpdateComponent) async {
        switch component.kind {
        case .app:
            // A modal sheet prevents Sparkle from terminating the app for
            // relaunch. Close the Update Center before handing off to it.
            isPresented = false
            await appUpdate.installUpdate()
        case .server:
            await machines.updateServer(machineId: component.machineId)
        case .harness:
            transientPhases[component.id] = .updating
            do {
                _ = try await machines.client(for: component.machineId)
                    .updateHarness(id: component.subjectId)
                transientPhases[component.id] = nil
                await refreshHarnesses(onMachine: component.machineId)
            } catch {
                transientPhases[component.id] = .failed(serverErrorMessage(error))
            }
        case .plugin:
            transientPhases[component.id] = .updating
            do {
                let client = machines.client(for: component.machineId)
                let plan = try await client.preparePluginUpdate(pluginId: component.subjectId)
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
        await run(components: components.filter(\.updateAvailable))
    }

    /// Installs the given components in order, persisting the remaining ids
    /// before each step so an interrupted run can pick up where it stopped.
    private func run(components snapshot: [UpdateComponent]) async {
        guard !isUpdatingAll, !snapshot.isEmpty else { return }
        isUpdatingAll = true
        defer { isUpdatingAll = false }
        var remaining = Set(snapshot.map(\.id))
        persistSession(remaining)
        for kind in [UpdateComponent.Kind.plugin, .harness, .server, .app] {
            for component in snapshot where component.kind == kind {
                await update(component)
                remaining.remove(component.id)
                persistSession(remaining)
            }
        }
        // An app component means Sparkle is restarting this client: leave
        // the (empty) session for the relaunched app to consume — reopening
        // this surface is the visible "it worked". Otherwise the run is
        // simply over.
        if !snapshot.contains(where: { $0.kind == .app }) {
            clearSession()
        }
    }

    /// Continues an update-all interrupted by the app's own restart (the
    /// normal final step) or a crash: reopens the surface, refreshes, and
    /// installs whatever is both still pending and still updatable.
    public func resumePendingSessionIfNeeded() async {
        guard let remaining = loadSession() else { return }
        isPresented = true
        await refresh(force: true)
        let pending = components.filter { remaining.contains($0.id) && $0.updateAvailable }
        if pending.isEmpty {
            clearSession()
        } else {
            await run(components: pending)
        }
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

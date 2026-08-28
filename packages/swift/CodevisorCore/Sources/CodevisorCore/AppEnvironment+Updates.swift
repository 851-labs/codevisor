import Foundation

/// Environment surface split from the class body to keep
/// AppEnvironment.swift within size limits.
extension AppEnvironment {
    public var serverClient: any CodevisorServerClienting { machines.selectedClient }

    public var harnessService: any HarnessServicing {
        harnessService(for: machines.selectedMachineId)
    }

    /// Starts the selected machine if it is local, then refreshes cached server
    /// state. Remote machines are never auto-started.
    public func prepareSelectedMachine() async {
        await machines.prepareSelectedMachine()
    }

    /// A machine's connection just came up: converge it with the config
    /// plane now rather than on the next periodic sweep.
    func noteMachineConnected(_ machineId: String) {
        Task { await configSync.synchronizeMachine(machineId) }
    }

    /// Change-driven application of replicated namespaces.
    // MARK: - Harness catalog (moved from AppEnvironment.swift for the size ratchet)

    public func harnessService(for serverId: String) -> any HarnessServicing {
        harnessServiceOverride ?? ServerHarnessService(client: machines.client(for: serverId))
    }

    /// The current catalog invalidation token for a machine. Views observe
    /// this value and refetch only the machine whose harness state changed.
    public func harnessCatalogRevision(for serverId: String) -> UInt64 {
        harnessCatalogRevisions[serverId, default: 0]
    }

    /// Lifecycle-decorated harnesses (update knowledge, install methods) per
    /// machine, fetched separately from the picker's plain list so the
    /// composer stays snappy. Update banners read this; composer surfaces
    /// refresh it via `refreshHarnessLifecycle`.
    public func harnessLifecycle(for serverId: String) -> [ServerHarness] {
        harnessLifecycleByServer[serverId] ?? []
    }

    public func refreshHarnessLifecycle(for serverId: String) async {
        guard let harnesses = try? await harnessService(for: serverId).allHarnesses() else { return }
        harnessLifecycleByServer[serverId] = harnesses
    }

    /// Installs the lifecycle returned by a successful start request before
    /// the optimistic client spinner is released. Events remain the ongoing
    /// source of truth; this closes the 202/event handoff gap.
    public func setHarnessLifecycle(
        _ lifecycle: ServerHarnessLifecycleState,
        harnessId: String,
        onServer serverId: String
    ) {
        guard var harnesses = harnessLifecycleByServer[serverId],
            let index = harnesses.firstIndex(where: { $0.id == harnessId })
        else { return }
        harnesses[index].lifecycle = lifecycle
        harnessLifecycleByServer[serverId] = harnesses
    }

    /// Publishes that authentication, enablement, or discovery changed the
    /// harnesses available for new chats on a machine.
    public func harnessCatalogDidChange(onServer serverId: String) {
        configCache.invalidateCapabilities(forServer: serverId)
        harnessCatalogRevisions[serverId, default: 0] &+= 1
    }

    /// Forces the server to re-probe harness authentication, then invalidates
    /// every mounted consumer of that machine's catalog.
    public func refreshHarnessAuthentication() async throws -> [ServerHarness] {
        // Snapshot before awaiting so a machine switch cannot attribute the
        // completed request to whichever machine happens to be selected later.
        let serverId = machines.selectedMachineId
        let refreshed = try await machines.client(for: serverId).refreshHarnessAuth()
        harnessCatalogDidChange(onServer: serverId)
        return refreshed
    }

    /// Re-probes only the harness whose authentication changed, then
    /// invalidates mounted consumers of that machine's catalog. Pass
    /// `onServer` when the caller is pinned to a machine (machine-scoped
    /// Settings pages); it defaults to the selected machine.
    public func refreshHarnessAuthentication(
        harnessId: String,
        onServer serverId: String? = nil
    ) async throws -> ServerHarness {
        let serverId = serverId ?? machines.selectedMachineId
        let refreshed = try await machines.client(for: serverId).refreshHarnessAuth(harnessId: harnessId)
        harnessCatalogDidChange(onServer: serverId)
        return refreshed
    }

    func applySyncedNamespace(_ namespace: String) {
        if namespace == "settings" { applySyncedSettings() }
        // New skill metadata means some machine is missing the content blob
        // behind it; ferry immediately instead of waiting for the sweep.
        if namespace == "skills" { Task { await configSync.synchronizeSkills() } }
        if namespace == FleetRoster.namespace { Task { await fleetRoster.applyRoster() } }
        // Fleet-wide harness state moved (enables, accounts, ferried
        // credentials): every machine's picker catalog is now suspect. Mark
        // them all stale — the reconcile-response hook refines per machine
        // as applies actually land.
        if namespace == "harnesses" || namespace == "harness-accounts"
            || namespace == "harness-credentials"
        {
            for machine in machines.allMachines {
                harnessCatalogDidChange(onServer: machine.id)
            }
        }
    }

    /// Applies everything the local replica already knows at startup.
    func applyBootSyncState() {
        applySyncedSettings()
        Task { await fleetRoster.applyRoster() }
    }

    public var sessionImporter: SessionImporter {
        SessionImporter(harnessService: harnessService)
    }

    /// True while an app self-update or a selected-server update is installing.
    /// Drives the composer lock so no new turn starts during the restart.
    public var isUpdateInProgress: Bool {
        appUpdate.isUpdating || machines.serverUpdatePhase == .updating
    }

    /// A machine's harness lifecycle changed (install/update progress): the
    /// catalog consumers invalidate, and the update center re-reads that
    /// machine's inventory so its rows track the operation.
    func noteHarnessLifecycle(onServer serverId: String) {
        harnessCatalogDidChange(onServer: serverId)
        updateCenter.noteHarnessLifecycleChanged(onServer: serverId)
    }

    /// Changes update channels immediately; the Settings view follows this
    /// with a fresh check so the state updates without a relaunch. The
    /// channel is FLEET state: it replicates through the config plane so
    /// every machine — and every other client — follows.
    public func setAlphaUpdatesEnabled(_ enabled: Bool) {
        settings.setAlphaUpdatesEnabled(enabled)
        appUpdate.setAllowsAlphaUpdates(enabled)
        machines.serverUpdateChannel = enabled ? .alpha : .stable
        configSync.set(
            namespace: "settings",
            key: "updateChannel",
            value: .string(enabled ? "alpha" : "stable")
        )
        Task { [machines] in
            await machines.refreshStatus(for: machines.selectedMachineId)
        }
    }

    /// Applies remotely-synced settings to this client. Loop-safe: local
    /// state changes only when it actually differs, and nothing here writes
    /// back into the replica.
    func applySyncedSettings() {
        guard
            case let .string(channel)? = configSync.value(
                namespace: "settings",
                key: "updateChannel"
            )
        else { return }
        let alpha = channel == "alpha"
        guard alpha != settings.alphaUpdatesEnabled else { return }
        settings.setAlphaUpdatesEnabled(alpha)
        appUpdate.setAllowsAlphaUpdates(alpha)
        machines.serverUpdateChannel = alpha ? .alpha : .stable
    }

    // MARK: - Session import discovery (moved from AppEnvironment.swift for the size ratchet)

    /// Project-folder suggestions for an explicit machine. Discovery and path
    /// validation run on that machine, which is required for remote and iOS
    /// clients whose local filesystem cannot resolve the returned paths.
    public func recommendedProjects(
        serverId: String,
        limit: Int = 12
    ) async throws -> [ProjectRecommendation] {
        let records = try await machines.client(for: serverId).projectRecommendations(limit: limit)
        return records.map { record in
            ProjectRecommendation(
                folderURL: URL(fileURLWithPath: record.path),
                name: record.name,
                sessionCount: record.sessionCount,
                lastActivity: record.lastActivity.flatMap(Self.recommendationDate(from:))
            )
        }
    }

    /// Backward-compatible selected-machine entry point used by onboarding.
    /// Older servers lack the recommendation endpoint, so the local desktop
    /// path retains the existing client-side fallback.
    public func recommendedProjects(limit: Int = 12) async -> [ProjectRecommendation] {
        let serverId = machines.selectedMachineId
        if let remote = try? await recommendedProjects(serverId: serverId, limit: limit) {
            return remote
        }
        let imported = await sessionImporter.fetchAll()
        // Recommendation probes the filesystem per session (worktree `.git`
        // metadata, directory checks); keep those syscalls off the main actor.
        return await Task.detached {
            ProjectRecommender.recommend(from: imported, limit: limit)
        }.value
    }

    private static func recommendationDate(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    /// Harness sessions whose working directory is the given folder and that
    /// aren't already tracked by Codevisor.
    public func findImportableSessions(for folderURL: URL) async -> [ImportedSession] {
        let folderPath = folderURL.standardizedFileURL.path
        let imported = await sessionImporter.fetchAll()
        // Snapshot the main-actor state the filter reads, then run the
        // O(imported × known) scan and per-item URL standardization off the
        // main actor. All values involved are Sendable value types.
        let serverId = machines.selectedMachineId
        let knownSessions = projectList.sessions
        return await Task.detached {
            imported.filter { item in
                let matchesFolder = URL(fileURLWithPath: item.info.cwd).standardizedFileURL.path == folderPath
                let alreadyKnown = knownSessions.contains {
                    $0.serverId == serverId
                        && $0.harnessId == item.harnessId
                        && $0.agentSessionId == item.info.sessionId
                }
                return matchesFolder && !alreadyKnown
            }
        }.value
    }
}

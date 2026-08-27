import Foundation
import Observation

/// One machine's live client-side state, owned by `MachineController`.
///
/// This is the single home for everything the app knows about a machine at
/// runtime — reachability, release state, availability, and navigation-sync
/// state — replacing the controller's parallel per-machine dictionaries.
/// Consolidating here is what lets every machine carry its own lifecycle
/// (its own event stream, its own update in flight) instead of the selected
/// machine's state being the only state that exists.
@MainActor
@Observable
public final class MachineConnection {
    public let machineId: String

    /// Last status probe result (reachability + display label).
    public internal(set) var status: MachineStatus?
    /// Last release-state check for this machine's server.
    public internal(set) var updateInfo: ServerUpdateInfo?
    /// Whether ordinary requests to this machine are flowing, waiting on a
    /// known startup/restart, or failed.
    public internal(set) var availability: ServerAvailability?
    /// How current this machine's synced navigation snapshot is.
    public internal(set) var navigationSyncState: NavigationSyncState?
    /// Progress of a client-triggered update of THIS machine's server. Per
    /// machine so one machine's in-flight update never shows on another,
    /// and switching away never abandons the tracking.
    public internal(set) var updatePhase: ServerUpdatePhase = .idle

    /// This machine's live shell-event subscription. Every machine holds its
    /// own; selection changes never touch another machine's stream.
    @ObservationIgnored var eventSyncTask: Task<Void, Never>?
    /// Guards one background connect at a time per machine.
    @ObservationIgnored var backgroundConnectInFlight = false
    /// Consecutive background stream failures, for reconnect backoff. Reset
    /// on the first event a fresh subscription delivers.
    @ObservationIgnored var reconnectFailures = 0

    init(machineId: String) {
        self.machineId = machineId
    }
}

extension MachineController {
    /// The controller's persistence store, shared with collaborators that
    /// persist their own small records (the update center's session).
    var persistenceStore: any PersistenceStore { store }

    /// The connection record for a machine, created on first touch.
    func connection(for machineId: String) -> MachineConnection {
        if let existing = connectionsById[machineId] { return existing }
        let connection = MachineConnection(machineId: machineId)
        connectionsById[machineId] = connection
        return connection
    }

    /// Drops a machine's connection record entirely (machine removed). Its
    /// status in particular carries the cloud device id that deduplicates
    /// the cloud machine list — left behind, it would keep hiding the
    /// machine's cloud twin.
    func removeConnection(for machineId: String) {
        connectionsById[machineId]?.eventSyncTask?.cancel()
        connectionsById[machineId] = nil
    }

    // MARK: - Per-machine lifecycle

    func beginWaiting(for machineId: String, reason: ServerWaitingReason) {
        if let navigationSyncMachineId, navigationSyncMachineId != machineId {
            navigationSyncTask?.cancel()
            self.navigationSyncMachineId = nil
            navigationSyncToken = nil
            navigationSyncTask = nil
        }
        // Only THIS machine's stream stops; every other machine keeps
        // streaming through the transition.
        stopEventSync(for: machineId)
        if machineId == selectedMachineId {
            pendingRefreshTask?.cancel()
            pendingRefreshTask = nil
        }
        let connection = connection(for: machineId)
        connection.availability = .waiting(reason)
        connection.navigationSyncState = .catchingUp
        requestGate.beginWaiting(for: machineId)
    }

    func markReady(for machineId: String) {
        connection(for: machineId).availability = .ready
        requestGate.markReady(for: machineId)
    }

    func markFailed(for machineId: String, message: String) {
        let connection = connection(for: machineId)
        connection.availability = .failed(message)
        connection.navigationSyncState = .stale(message)
        requestGate.markFailed(for: machineId, message: message)
    }

    public func retrySelectedMachine() async {
        let machine = selectedMachine
        beginWaiting(for: machine.id, reason: machine.isLocal ? .starting : .connecting)
        await prepareSelectedMachine()
    }

    /// Removes everything stored under a configured machine's own cloud
    /// twin id: its stream, and every project/session/workspace record that
    /// synced under the duplicate identity.
    func pruneCloudTwinRecords(deviceId: String) {
        let twinId = CodevisorMachine.cloudIdPrefix + deviceId
        removeConnection(for: twinId)
        projectList.removeAllRecords(serverId: twinId)
        workspaceSync?.removeWorkspaces(serverId: twinId)
    }

    /// Cloud ids whose device is already served by a configured machine —
    /// connecting to them would resurrect the duplicate records the prune
    /// above removes.
    func isCloudTwinOfConfiguredMachine(_ machineId: String) -> Bool {
        guard let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: machineId) else {
            return false
        }
        let configuredIds = Set(machines.map(\.id))
        return statusByMachineId.contains { key, status in
            configuredIds.contains(key) && status.cloudDeviceId == deviceId
        }
    }

    /// Opens a machine's live event stream in the background — status probe,
    /// cursor capture, then subscribe — without touching selection, the
    /// request gate, or navigation sync. The selected machine's lifecycle
    /// stays with `prepareSelectedMachine`; this exists so every OTHER
    /// machine's sessions keep flowing while it is off screen.
    public func connectMachine(_ machineId: String) async {
        guard machine(for: machineId) != nil else { return }
        guard !isCloudTwinOfConfiguredMachine(machineId) else { return }
        let connection = connection(for: machineId)
        guard connection.eventSyncTask == nil, !connection.backgroundConnectInFlight else {
            return
        }
        connection.backgroundConnectInFlight = true
        defer { connection.backgroundConnectInFlight = false }
        let client = client(for: machineId)
        await refreshStatus(for: machineId)
        guard connection.status?.isReachable == true else { return }
        let cursor = (try? await client.latestShellEventCursor()) ?? 0
        // Full snapshot BEFORE the stream starts (the cursor above replays
        // anything racing the fetch): a machine's chats and workspaces are
        // present — and orderable in a flattened sidebar — without it ever
        // being selected.
        await projectList.refreshFromServer(serverId: machineId, client: client)
        await workspaceSync?.refreshFromServer(serverId: machineId, client: client)
        // Selection may have taken this machine over while we probed; its
        // navigation sync owns the stream then.
        guard connection.eventSyncTask == nil else { return }
        startEventSync(serverId: machineId, client: client, since: cursor)
        onMachineConnected?(machineId)
    }

    /// Ensures every registered machine has a live event stream. Safe to
    /// call often: machines already streaming (or mid-connect) are skipped,
    /// and failed probes simply retry on the next pass.
    public func ensureBackgroundConnections() {
        for machine in allMachines where machine.id != selectedMachineId {
            let connection = connection(for: machine.id)
            guard connection.eventSyncTask == nil, !connection.backgroundConnectInFlight else {
                continue
            }
            Task { await self.connectMachine(machine.id) }
        }
    }

    public var selectedServerAvailability: ServerAvailability {
        availabilityByMachineId[selectedMachineId] ?? .ready
    }

    public var selectedNavigationSyncState: NavigationSyncState {
        navigationSyncStateByMachineId[selectedMachineId] ?? .cached
    }

    public var selectedMachineId: String {
        registry.selectedMachineId
    }

    public var selectedMachine: CodevisorMachine {
        machine(for: registry.selectedMachineId) ?? CodevisorMachine.local
    }

    public var selectedClient: any CodevisorServerClienting {
        client(for: selectedMachine.id)
    }

    public var machines: [CodevisorMachine] {
        // Client-only platforms (no local server) have no "Local" machine at
        // all — their fleet is exactly the configured remotes. Only platforms
        // that actually run a server alongside the app list it.
        (localServer == nil ? [] : [CodevisorMachine.local]) + registry.remoteMachines
    }

    public func machine(for id: String) -> CodevisorMachine? {
        allMachines.first { $0.id == id }
    }

    /// A machine's display name as ROW METADATA for flattened lists: nil
    /// for single-machine fleets, so machine context never appears until
    /// it actually means something.
    public func fleetMachineName(for serverId: String) -> String? {
        guard allMachines.count > 1 else { return nil }
        return machine(for: serverId)?.name
    }

    /// Resolves a fleet sync key (a server's config.id, how its entries are
    /// keyed in synced namespaces) back to the CLIENT-side machine id, via
    /// the id each reachable server reported in /v1/info. "local" is the
    /// local server's own id. Nil when no known machine reported that id.
    public func machineId(forSyncKey key: String) -> String? {
        if key == CodevisorMachine.local.id { return CodevisorMachine.local.id }
        return statusByMachineId.first { $0.value.serverId == key }?.key
    }

    /// The inverse of `machineId(forSyncKey:)`: the key a machine's server
    /// uses for its single-writer sync entries. The local server identifies
    /// as "local"; remotes report their id via /v1/info. Nil until a remote
    /// has been probed — its readiness cannot be read yet either.
    public func syncKey(forMachineId id: String) -> String? {
        if id == CodevisorMachine.local.id { return CodevisorMachine.local.id }
        return statusByMachineId[id]?.serverId
    }

    /// The display name for a sync key: the matching machine's fleet name,
    /// else the raw key (a machine that vanished or was never probed).
    public func fleetName(forSyncKey key: String) -> String {
        guard let machineId = machineId(forSyncKey: key) else { return key }
        return fleetMachineName(for: machineId) ?? key
    }

    /// The cloud presence entry backing a `cloud:` machine id, if any.
    public func cloudMachine(forMachineId id: String) -> CloudMachine? {
        guard let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: id),
            let cloudProvider, cloudProvider.isCloudSignedIn
        else { return nil }
        return cloudProvider.cloudMachines.first { $0.deviceId == deviceId }
    }

    /// This machine's stable connection token (the loopback call is exempt
    /// from token auth), for pasting into another device's Add Remote Machine
    /// sheet. Stable across restarts so the copied value keeps working.
    public func issueLocalConnectionToken() async throws -> String {
        try await client(for: CodevisorMachine.local.id).connectionToken().token
    }

    /// Records the onboarding sync choice on the machine itself — the server
    /// enforces it (see /v1/sync-participation). Fire-and-forget: the flag
    /// defaults to participating server-side, and an unreachable machine
    /// simply keeps its current state.
    public func applySyncParticipation(_ machineId: String, enabled: Bool) {
        let client = client(for: machineId)
        Task { _ = try? await client.setSyncParticipation(enabled: enabled) }
    }

    // MARK: - Legacy projections

    /// Read-only per-machine projections retained for existing consumers;
    /// the connections themselves are the source of truth.

    public var statusByMachineId: [String: MachineStatus] {
        connectionsById.compactMapValues(\.status)
    }

    public var updateInfoByMachineId: [String: ServerUpdateInfo] {
        connectionsById.compactMapValues(\.updateInfo)
    }

    public var availabilityByMachineId: [String: ServerAvailability] {
        connectionsById.compactMapValues(\.availability)
    }

    public var navigationSyncStateByMachineId: [String: NavigationSyncState] {
        connectionsById.compactMapValues(\.navigationSyncState)
    }
}

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

    /// Opens a machine's live event stream in the background — status probe,
    /// cursor capture, then subscribe — without touching selection, the
    /// request gate, or navigation sync. The selected machine's lifecycle
    /// stays with `prepareSelectedMachine`; this exists so every OTHER
    /// machine's sessions keep flowing while it is off screen.
    public func connectMachine(_ machineId: String) async {
        guard machine(for: machineId) != nil else { return }
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
        // Selection may have taken this machine over while we probed; its
        // navigation sync owns the stream then.
        guard connection.eventSyncTask == nil else { return }
        startEventSync(serverId: machineId, client: client, since: cursor)
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

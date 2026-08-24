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
        connectionsById[machineId] = nil
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

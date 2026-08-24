import ACPKit
import Foundation

/// The machine list as replicated config: the "machines" namespace holds
/// one entry per direct remote, keyed by the machine's STABLE server id
/// and valued { name, url, token }. Publishing side: a client that adds or
/// removes a remote records it here, so every other client learns about it
/// through ordinary gossip ("phone adds Linux → it appears on the Mac").
/// Applying side: unknown live entries become remote machines quietly
/// (selection stays put) and tombstones remove the machines they named.
///
/// Trust model, stated plainly: roster entries carry connection tokens, so
/// every participating machine's replica can reach every other one. Within
/// one owner's fleet that is the point — a machine's token already means
/// agent-level access to it, and the sync participation flag is the
/// opt-out for machines that should stay outside this boundary. Cloud
/// machines never enter the roster: account presence already carries them,
/// tokenlessly, to every signed-in client.
@MainActor
public final class FleetRoster {
    static let namespace = "machines"

    private let machines: MachineController
    private let configSync: ConfigSync
    private let store: any PersistenceStore
    /// Roster key (stable server id) → local machine id, for tombstones.
    private var appliedByKey: [String: String]
    private var cachedLocalServerId: String?

    public init(
        machines: MachineController,
        configSync: ConfigSync,
        store: (any PersistenceStore)? = nil
    ) {
        self.machines = machines
        self.configSync = configSync
        let store = store ?? machines.persistenceStore
        self.store = store
        if let data = store.loadData(forKey: "fleetRoster.applied"),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        {
            appliedByKey = decoded
        } else {
            appliedByKey = [:]
        }
    }

    // MARK: - Publishing

    /// A remote machine was added on THIS client: resolve its stable id and
    /// publish its route. Best-effort — an unreachable machine publishes on
    /// a later re-add (the fleet only learns routes that actually answered).
    public func publishMachine(_ machine: CodevisorMachine) {
        guard machine.kind == "remote" else { return }
        let client = machines.client(for: machine.id)
        Task { [weak self] in
            guard let info = try? await client.info() else { return }
            self?.record(machine: machine, serverId: info.id)
        }
    }

    /// A machine was removed on THIS client: tombstone it fleet-wide (a
    /// live roster entry would otherwise just re-add it everywhere).
    public func publishRemoval(localMachineId: String) {
        guard let key = appliedByKey.first(where: { $0.value == localMachineId })?.key else {
            return
        }
        appliedByKey[key] = nil
        persistApplied()
        configSync.remove(namespace: Self.namespace, key: key)
    }

    private func record(machine: CodevisorMachine, serverId: String) {
        appliedByKey[serverId] = machine.id
        persistApplied()
        var value: [String: JSONValue] = [
            "name": .string(machine.name),
            "url": .string(machine.baseURL.absoluteString),
        ]
        if let token = machine.token {
            value["token"] = .string(token)
        }
        // Idempotent republish (roster apply fires the added hook too):
        // identical state writes nothing, so gossip carries no churn.
        guard configSync.value(namespace: Self.namespace, key: serverId) != .object(value) else {
            return
        }
        configSync.set(namespace: Self.namespace, key: serverId, value: .object(value))
    }

    // MARK: - Applying

    /// Adopts the roster. Idempotent: known routes are skipped, unknown
    /// live entries join quietly, tombstones remove what they named, and
    /// this client's own machine never adds itself.
    public func applyRoster() async {
        let localServerId = await localId()
        for entry in configSync.entries(namespace: Self.namespace) {
            if entry.deleted == true {
                applyRemoval(key: entry.key)
                continue
            }
            guard entry.key != localServerId,
                case .object(let value) = entry.value,
                case .string(let urlString)? = value["url"],
                let url = URL(string: urlString)
            else { continue }
            if let existing = machines.allMachines.first(where: { $0.baseURL == url }) {
                appliedByKey[entry.key] = existing.id
                continue
            }
            var name: String?
            if case .string(let candidate)? = value["name"] { name = candidate }
            var token: String?
            if case .string(let candidate)? = value["token"] { token = candidate }
            guard
                let machine = try? machines.addRemote(
                    host: urlString,
                    name: name,
                    token: token,
                    select: false
                )
            else { continue }
            appliedByKey[entry.key] = machine.id
            let machineId = machine.id
            // Bring its stream up right away so status and events flow.
            Task { [machines] in await machines.connectMachine(machineId) }
        }
        persistApplied()
    }

    private func applyRemoval(key: String) {
        guard let localMachineId = appliedByKey[key] else { return }
        // Clear the mapping FIRST so the removal hook's publish is a no-op
        // (the tombstone already exists; re-stamping it would churn gossip).
        appliedByKey[key] = nil
        persistApplied()
        try? machines.removeMachine(localMachineId)
    }

    /// This client's own machine's stable server id (nil on clients with no
    /// local server, like iOS) — roster entries for it are skipped so a
    /// machine never adds itself as a remote.
    private func localId() async -> String? {
        if let cached = cachedLocalServerId { return cached }
        guard let info = try? await machines.client(for: CodevisorMachine.local.id).info() else {
            return nil
        }
        cachedLocalServerId = info.id
        return info.id
    }

    private func persistApplied() {
        guard let data = try? JSONEncoder().encode(appliedByKey) else { return }
        try? store.saveData(data, forKey: "fleetRoster.applied")
    }
}

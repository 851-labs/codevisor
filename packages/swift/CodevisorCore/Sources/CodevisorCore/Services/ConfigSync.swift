import ACPKit
import Foundation
import Observation

/// Client-side half of the config plane (@codevisor/sync): a durable local
/// replica of each namespace, plus the gossip that keeps every reachable
/// machine's replica converged. There is deliberately no authority server —
/// clients are the edges of the graph: a write here stamps a hybrid logical
/// clock and fans out to every reachable machine; a machine's sync.changed
/// event is adopted and re-gossiped onward; anything unreachable converges
/// on the next sweep.
@MainActor
@Observable
public final class ConfigSync {
    /// The namespaces this client gossips. Grows as stores onboard.
    public static let namespaces = ["settings"]

    private let machines: MachineController
    private let store: any PersistenceStore
    /// This client install's stable identity in HLC stamps.
    let deviceId: String
    /// Bumped whenever a namespace's replica actually changes — the
    /// invalidation observers watch instead of diffing entries.
    public private(set) var revisionsByNamespace: [String: UInt64] = [:]
    /// Invoked after a namespace's replica actually changed (local write or
    /// adopted remote entries) — consumers apply the new values in place.
    @ObservationIgnored public var onNamespaceChanged: ((String) -> Void)?
    @ObservationIgnored private var entriesByNamespace: [String: [ServerSyncEntry]] = [:]

    public init(machines: MachineController, store: (any PersistenceStore)? = nil) {
        self.machines = machines
        let store = store ?? machines.persistenceStore
        self.store = store
        if let data = store.loadData(forKey: "configSync.deviceId"),
            let existing = String(data: data, encoding: .utf8), !existing.isEmpty
        {
            deviceId = existing
        } else {
            let fresh = UUID().uuidString.lowercased()
            try? store.saveData(Data(fresh.utf8), forKey: "configSync.deviceId")
            deviceId = fresh
        }
    }

    // MARK: - Reading and writing

    public func entries(namespace: String) -> [ServerSyncEntry] {
        loadNamespace(namespace)
    }

    /// The live value for a key; nil when absent or tombstoned.
    public func value(namespace: String, key: String) -> JSONValue? {
        guard let entry = loadNamespace(namespace).first(where: { $0.key == key }),
            entry.deleted != true
        else { return nil }
        return entry.value
    }

    public func set(namespace: String, key: String, value: JSONValue) {
        write(namespace: namespace, key: key, value: value, deleted: false)
    }

    public func remove(namespace: String, key: String) {
        write(namespace: namespace, key: key, value: .null, deleted: true)
    }

    private func write(namespace: String, key: String, value: JSONValue, deleted: Bool) {
        let current = loadNamespace(namespace)
        let stamp = SyncClock.next(
            after: SyncClock.latest(in: current),
            deviceId: deviceId,
            nowMs: Int(Date().timeIntervalSince1970 * 1000)
        )
        let entry = ServerSyncEntry(
            key: key,
            value: value,
            deleted: deleted ? true : nil,
            timestamp: stamp
        )
        apply(namespace: namespace, incoming: [entry])
        pushEverywhere(namespace: namespace)
    }

    /// Merges entries into the local replica, bumping the namespace revision
    /// when anything actually changed.
    @discardableResult
    func apply(namespace: String, incoming: [ServerSyncEntry]) -> Bool {
        let result = SyncClock.merge(loadNamespace(namespace), incoming)
        guard !result.changed.isEmpty else { return false }
        entriesByNamespace[namespace] = result.merged
        persistNamespace(namespace)
        revisionsByNamespace[namespace, default: 0] &+= 1
        onNamespaceChanged?(namespace)
        return true
    }

    /// A machine's sync.changed event: adopt it, then gossip onward — a
    /// change entering through one machine still reaches machines the
    /// originating client cannot see.
    public func applyRemoteChange(namespace: String, entries incoming: [ServerSyncEntry]) {
        if apply(namespace: namespace, incoming: incoming) {
            pushEverywhere(namespace: namespace)
        }
    }

    // MARK: - Gossip

    /// One machine, one namespace set: PUT the local replica (the response
    /// is the merged document — push and pull in one round trip) and adopt
    /// anything newer it held.
    public func synchronize(machineId: String, namespaces: [String] = ConfigSync.namespaces) async {
        let client = machines.client(for: machineId)
        for namespace in namespaces {
            guard
                let document = try? await client.mergeSyncDocument(
                    namespace: namespace,
                    entries: loadNamespace(namespace)
                )
            else { continue }
            apply(namespace: namespace, incoming: document.entries)
        }
    }

    /// Every reachable machine. Safe to call often; merging is idempotent.
    public func synchronizeAll() async {
        for machine in machines.allMachines
        where machines.connectionsById[machine.id]?.status?.isReachable == true {
            await synchronize(machineId: machine.id)
        }
    }

    private func pushEverywhere(namespace: String) {
        let entries = loadNamespace(namespace)
        for machine in machines.allMachines
        where machines.connectionsById[machine.id]?.status?.isReachable == true {
            let client = machines.client(for: machine.id)
            Task {
                _ = try? await client.mergeSyncDocument(namespace: namespace, entries: entries)
            }
        }
    }

    // MARK: - Persistence

    private func loadNamespace(_ namespace: String) -> [ServerSyncEntry] {
        if let cached = entriesByNamespace[namespace] { return cached }
        let key = "configSync.replica.\(namespace)"
        var loaded: [ServerSyncEntry] = []
        if let data = store.loadData(forKey: key),
            let decoded = try? JSONDecoder().decode([ServerSyncEntry].self, from: data)
        {
            loaded = decoded
        }
        entriesByNamespace[namespace] = loaded
        return loaded
    }

    private func persistNamespace(_ namespace: String) {
        guard let data = try? JSONEncoder().encode(entriesByNamespace[namespace] ?? []) else {
            return
        }
        try? store.saveData(data, forKey: "configSync.replica.\(namespace)")
    }
}

/// Swift mirror of @codevisor/sync's hybrid logical clock and LWW merge.
/// Both sides MUST order and merge identically or replicas diverge; keep
/// any change in lockstep with packages/sync/src/index.ts.
enum SyncClock {
    static func compare(_ a: ServerSyncTimestamp, _ b: ServerSyncTimestamp) -> Int {
        if a.wallMs != b.wallMs { return a.wallMs < b.wallMs ? -1 : 1 }
        if a.counter != b.counter { return a.counter < b.counter ? -1 : 1 }
        if a.deviceId != b.deviceId { return a.deviceId < b.deviceId ? -1 : 1 }
        return 0
    }

    static func latest(in entries: [ServerSyncEntry]) -> ServerSyncTimestamp? {
        entries.map(\.timestamp).max { compare($0, $1) < 0 }
    }

    /// The next stamp to write with: at least the wall clock, strictly after
    /// everything seen.
    static func next(
        after: ServerSyncTimestamp?,
        deviceId: String,
        nowMs: Int
    ) -> ServerSyncTimestamp {
        guard let after, nowMs <= after.wallMs else {
            return ServerSyncTimestamp(wallMs: nowMs, counter: 0, deviceId: deviceId)
        }
        return ServerSyncTimestamp(
            wallMs: after.wallMs,
            counter: after.counter + 1,
            deviceId: deviceId
        )
    }

    /// Per-key last-writer-wins; idempotent and commutative.
    static func merge(
        _ current: [ServerSyncEntry],
        _ incoming: [ServerSyncEntry]
    ) -> (merged: [ServerSyncEntry], changed: [ServerSyncEntry]) {
        var byKey: [String: ServerSyncEntry] = [:]
        for entry in current {
            byKey[entry.key] = entry
        }
        var changed: [ServerSyncEntry] = []
        for entry in incoming {
            if let existing = byKey[entry.key], compare(entry.timestamp, existing.timestamp) <= 0 {
                continue
            }
            byKey[entry.key] = entry
            changed.append(entry)
        }
        let merged = byKey.values.sorted { $0.key < $1.key }
        return (merged, changed)
    }
}

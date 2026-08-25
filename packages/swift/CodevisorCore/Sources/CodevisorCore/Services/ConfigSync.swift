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
    public static let namespaces = [
        "settings", "skills", "mcps", "harness-accounts", "machines", "harnesses",
    ]

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

    /// One machine's full pass — run the moment its connection comes up, so
    /// a freshly joined (or newly reachable) machine converges immediately
    /// instead of on the next periodic sweep.
    public func synchronizeMachine(_ machineId: String) async {
        let client = machines.client(for: machineId)
        await synchronize(machineId: machineId)
        _ = try? await client.reconcileMcpsSync()
        _ = try? await client.reconcileHarnessesSync()
        try? await client.publishAccountsSync()
        await synchronizeSkills()
    }

    /// Every reachable machine. Safe to call often; merging is idempotent.
    public func synchronizeAll() async {
        for machine in machines.allMachines
        where machines.connectionsById[machine.id]?.status?.isReachable == true {
            let client = machines.client(for: machine.id)
            await synchronize(machineId: machine.id)
            // Reconcile the machine's applied state against its (just
            // gossiped) replicas, and refresh its published roster.
            _ = try? await client.reconcileMcpsSync()
            _ = try? await client.reconcileHarnessesSync()
            try? await client.publishAccountsSync()
        }
        await synchronizeSkills()
    }

    // MARK: - Skills ferry

    /// Skills replicate as metadata (the "skills" namespace, gossiped
    /// above) plus content-addressed archives servers cannot fetch from
    /// each other. This client is the courier: reconcile everywhere,
    /// collect who is missing which blob, carry each blob from any machine
    /// that serves it, then reconcile the needy machines again so they
    /// apply what just arrived.
    public func synchronizeSkills() async {
        let reachable = machines.allMachines.filter {
            machines.connectionsById[$0.id]?.status?.isReachable == true
        }
        var missing: [(machineId: String, hash: String)] = []
        for machine in reachable {
            guard
                let status = try? await machines.client(for: machine.id).reconcileSkillsSync()
            else { continue }
            for item in status.missingBlobs {
                missing.append((machine.id, item.hash))
            }
        }
        guard !missing.isEmpty else { return }
        var blobCache: [String: Data] = [:]
        var ferried: Set<String> = []
        for item in missing {
            var bytes = blobCache[item.hash]
            if bytes == nil {
                let donors = reachable.map(\.id).filter { $0 != item.machineId }
                bytes = await firstBlob(hash: item.hash, from: donors)
                if let bytes { blobCache[item.hash] = bytes }
            }
            guard let bytes else { continue }
            if (try? await machines.client(for: item.machineId).putSyncBlob(
                id: item.hash,
                bytes: bytes
            )) != nil {
                ferried.insert(item.machineId)
            }
        }
        for machineId in ferried {
            _ = try? await machines.client(for: machineId).reconcileSkillsSync()
        }
    }

    private func firstBlob(hash: String, from machineIds: [String]) async -> Data? {
        for machineId in machineIds {
            if let bytes = try? await machines.client(for: machineId).syncBlob(id: hash) {
                return bytes
            }
        }
        return nil
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

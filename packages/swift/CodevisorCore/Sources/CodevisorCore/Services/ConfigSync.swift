import ACPKit
import Foundation
import Observation

@MainActor
@Observable
public final class ConfigSync {
  public static let namespaces = [
    "settings", skillsNamespace, "mcps", "harness-accounts", "harnesses", "plugins",
    "mcp-readiness", "mcp-overlays", "harness-credentials", "harness-shared-accounts", "harness-readiness",
    "plugin-readiness", ClientPreferenceSync.namespace,
  ]
  public static let skillsNamespace = "codevisor-skills"

  private let machines: MachineController
  private let store: any PersistenceStore
  let deviceId: String
  public private(set) var revisionsByNamespace: [String: UInt64] = [:]
  public private(set) var receivedNamespaces: Set<String> = []
  @ObservationIgnored public var onNamespaceChanged: ((String) -> Void)?
  @ObservationIgnored public var onHarnessCatalogChanged: ((String) -> Void)?
  @ObservationIgnored private var entriesByNamespace: [String: [ServerSyncEntry]] = [:]

  @ObservationIgnored private var periodicSweepTask: Task<Void, Never>?

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

  public func entries(namespace: String) -> [ServerSyncEntry] {
    loadNamespace(namespace)
  }

  public func hasSnapshot(namespace: String) -> Bool {
    receivedNamespaces.contains(namespace) || store.loadData(forKey: "configSync.replica.\(namespace)") != nil
  }

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

  public func applyRemoteChange(namespace: String, entries incoming: [ServerSyncEntry]) {
    if apply(namespace: namespace, incoming: incoming) {
      pushEverywhere(namespace: namespace)
    }
  }

  public func synchronize(machineId: String, namespaces: [String] = ConfigSync.namespaces) async {
    let client = machines.client(for: machineId)
    if namespaces.contains("harness-shared-accounts"),
      await machines.cloudProvider?.prepareAccountSync(on: client, machineId: machineId) == true
    {
      await machines.refreshStatus(for: machineId)
    }
    let documents = await mergeNamespaceDocuments(client: client, namespaces: namespaces)
    adoptNamespaceDocuments(documents, namespaces: namespaces)
  }

  private func mergeNamespaceDocuments(
    client: any CodevisorServerClienting,
    namespaces: [String]
  ) async -> [String: ServerSyncDocument] {
    let outgoing = namespaces.map { ($0, loadNamespace($0)) }
    let documents = await withTaskGroup(of: (String, ServerSyncDocument?).self) { group in
      for (namespace, entries) in outgoing {
        group.addTask { (namespace, try? await client.mergeSyncDocument(namespace: namespace, entries: entries)) }
      }
      var documents: [String: ServerSyncDocument] = [:]
      for await (namespace, document) in group { documents[namespace] = document }
      return documents
    }
    return documents
  }

  private func adoptNamespaceDocuments(
    _ documents: [String: ServerSyncDocument],
    namespaces: [String]
  ) {
    for namespace in namespaces {
      guard let document = documents[namespace] else { continue }
      apply(namespace: namespace, incoming: document.entries)
      receivedNamespaces.insert(namespace)
      persistNamespace(namespace)
    }
  }

  public func synchronizeMachine(_ machineId: String) async {
    let client = machines.client(for: machineId)
    await synchronize(machineId: machineId)
    _ = try? await client.reconcileMcpsSync()
    _ = try? await client.reconcileHarnessesSync()
    _ = try? await client.reconcilePluginsSync()
    try? await client.publishAccountsSync()
    await synchronizeSkills()
  }

  public func startPeriodicSweep(every interval: Duration = .seconds(300)) {
    periodicSweepTask?.cancel()
    periodicSweepTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else { return }
        await self?.synchronizeAll()
      }
    }
  }

  public func stopPeriodicSweep() {
    periodicSweepTask?.cancel()
    periodicSweepTask = nil
  }

  public func synchronizeAll() async {
    for machine in machines.allMachines
    where machines.connectionsById[machine.id]?.status?.isReachable == true {
      let client = machines.client(for: machine.id)
      await synchronize(machineId: machine.id)
      _ = try? await client.reconcileMcpsSync()
      _ = try? await client.reconcileHarnessesSync()
      _ = try? await client.reconcilePluginsSync()
      try? await client.publishAccountsSync()
    }
    await synchronizeSkills()
  }

  public func synchronizeSkills() async {
    let reachable = machines.allMachines.filter {
      machines.connectionsById[$0.id]?.status?.isReachable == true
    }
    let missing = await collectMissingSkillBlobs(from: reachable)
    guard !missing.isEmpty else { return }
    await ferryMissingSkillBlobs(missing, reachable: reachable)
  }

  private func collectMissingSkillBlobs(
    from reachable: [CodevisorMachine]
  ) async -> [(machineId: String, hash: String)] {
    var missing: [(machineId: String, hash: String)] = []
    for machine in reachable {
      guard
        let status = try? await machines.client(for: machine.id).reconcileSkillsSync()
      else { continue }
      for item in status.missingBlobs {
        missing.append((machine.id, item.hash))
      }
    }
    return missing
  }

  private func ferryMissingSkillBlobs(
    _ missing: [(machineId: String, hash: String)],
    reachable: [CodevisorMachine]
  ) async {
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
        guard
          (try? await client.mergeSyncDocument(namespace: namespace, entries: entries))
            != nil
        else { return }
        await self.reconcile(namespace: namespace, machineId: machine.id)
      }
    }
    if namespace == Self.skillsNamespace {
      Task { await synchronizeSkills() }
    }
  }

  private func reconcile(namespace: String, machineId: String) async {
    let client = machines.client(for: machineId)
    switch namespace {
    case "mcps": _ = try? await client.reconcileMcpsSync()
    case "harnesses":
      guard let status = try? await client.reconcileHarnessesSync() else { return }
      if !status.applied.isEmpty || !status.removed.isEmpty || !status.installing.isEmpty {
        onHarnessCatalogChanged?(machineId)
      }
    case "plugins": _ = try? await client.reconcilePluginsSync()
    case "harness-credentials", "harness-shared-accounts":
      guard let value = try? await client.reconcileCredentialsSync() else { return }
      if case .object(let fields) = value,
        case .array(let applied)? = fields["applied"],
        !applied.isEmpty
      {
        onHarnessCatalogChanged?(machineId)
      }
    default: break
    }
  }

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

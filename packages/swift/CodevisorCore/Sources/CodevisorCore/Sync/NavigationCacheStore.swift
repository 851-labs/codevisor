import Foundation

/// Keeps each machine's navigation cache on disk, so the next launch can show
/// the last known state immediately instead of waiting for the network.
///
/// One key per machine keeps a delta from rewriting every machine's data, and
/// an index key records which machines have a cache.
@MainActor
final class NavigationCacheStore {
  nonisolated static let keyPrefix = "navigation-cache-v1."
  nonisolated static let indexKey = "navigation-cache-v1-index"

  private(set) var caches: [String: MachineNavigationCache] = [:]
  /// Advances whenever a machine's cache is replaced or removed, so a
  /// rebuild can tell which machines changed without comparing snapshots.
  private(set) var generations: [String: UInt64] = [:]
  private let store: any PersistenceStore
  private let persistenceOwner = UUID()

  init(store: any PersistenceStore) {
    self.store = store
    let decoder = JSONDecoder()
    let machineIds =
      store.loadData(forKey: Self.indexKey).flatMap { try? decoder.decode([String].self, from: $0) } ?? []
    for machineId in machineIds {
      let key = Self.keyPrefix + machineId
      guard let data = store.loadData(forKey: key) else { continue }
      do {
        let snapshot = try decoder.decode(ServerNavigationSnapshot.self, from: data)
        caches[machineId] = MachineNavigationCache(machineId: machineId, snapshot: snapshot)
      } catch {
        // A cache is disposable: an unreadable one just means this machine
        // shows a spinner once, until its next snapshot arrives.
        handleCorruptPayload(store: store, key: key, data: data, error: error)
      }
    }
  }

  func set(_ cache: MachineNavigationCache) {
    let isNew = caches[cache.machineId] == nil
    caches[cache.machineId] = cache
    generations[cache.machineId, default: 0] &+= 1
    let store = store
    let snapshot = cache.snapshot
    let key = Self.keyPrefix + cache.machineId
    PersistenceEncoding.enqueueLatest(owner: persistenceOwner, key: key) {
      do {
        try store.saveData(PersistenceEncoding.encoder.encode(snapshot), forKey: key)
      } catch {
        Log.persistence.error("Failed to save \(key, privacy: .public): \(String(describing: error), privacy: .public)")
      }
    }
    if isNew { persistIndex() }
  }

  func remove(machineId: String) {
    guard caches.removeValue(forKey: machineId) != nil else { return }
    generations[machineId, default: 0] &+= 1
    let store = store
    let key = Self.keyPrefix + machineId
    PersistenceEncoding.enqueueLatest(owner: persistenceOwner, key: key, delay: 0) {
      try? store.removeData(forKey: key)
    }
    persistIndex()
  }

  private func persistIndex() {
    let store = store
    let machineIds = caches.keys.sorted()
    PersistenceEncoding.enqueueLatest(owner: persistenceOwner, key: Self.indexKey, delay: 0) {
      try? store.saveData(JSONEncoder().encode(machineIds), forKey: Self.indexKey)
    }
  }
}

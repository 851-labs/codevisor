import Foundation

enum LegacyNavigationCacheImport {
  static let keyPrefix = "navigation-cache-v1."
  static let indexKey = "navigation-cache-v1-index"

  static func run(store: any PersistenceStore, cache: ClientCache) {
    let machineIds = legacyMachineIds(in: store)
    guard !machineIds.isEmpty else { return }

    do {
      try cache.adoptLegacyNavigation(snapshots(for: machineIds, in: store))
    } catch {
      Log.clientCache.error("Could not import the old sidebar cache: \(String(describing: error), privacy: .public)")
    }
    remove(machineIds, from: store)
  }

  private static func legacyMachineIds(in store: any PersistenceStore) -> [String] {
    store.loadData(forKey: indexKey).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
  }

  private static func snapshots(
    for machineIds: [String], in store: any PersistenceStore
  ) -> [String: ServerNavigationSnapshot] {
    var snapshots: [String: ServerNavigationSnapshot] = [:]
    for machineId in machineIds {
      guard let data = store.loadData(forKey: keyPrefix + machineId) else { continue }
      snapshots[machineId] = try? JSONDecoder().decode(ServerNavigationSnapshot.self, from: data)
    }
    return snapshots
  }

  private static func remove(_ machineIds: [String], from store: any PersistenceStore) {
    for machineId in machineIds { try? store.removeData(forKey: keyPrefix + machineId) }
    try? store.removeData(forKey: indexKey)
  }
}

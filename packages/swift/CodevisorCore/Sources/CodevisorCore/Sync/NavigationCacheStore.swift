import Foundation

@MainActor
final class NavigationCacheStore {
  private(set) var caches: [String: MachineNavigationCache] = [:]
  private(set) var generations: [String: UInt64] = [:]
  private let clientCache: ClientCache?

  init(preloaded: [String: MachineNavigationCache]? = nil, clientCache: ClientCache? = nil) {
    self.clientCache = clientCache
    caches = preloaded ?? Self.loadCaches(from: clientCache)
  }

  nonisolated static func loadCaches(from clientCache: ClientCache?) -> [String: MachineNavigationCache] {
    let snapshots = clientCache?.loadNavigation() ?? [:]
    return snapshots.reduce(into: [:]) { caches, entry in
      caches[entry.key] = MachineNavigationCache(machineId: entry.key, snapshot: entry.value)
    }
  }

  func set(_ cache: MachineNavigationCache) {
    caches[cache.machineId] = cache
    generations[cache.machineId, default: 0] &+= 1
    clientCache?.recordNavigation(cache.snapshot, machineId: cache.machineId)
  }

  func remove(machineId: String) {
    guard caches.removeValue(forKey: machineId) != nil else { return }

    generations[machineId, default: 0] &+= 1
    clientCache?.forgetMachine(machineId)
  }
}

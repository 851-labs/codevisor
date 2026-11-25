import Foundation

@MainActor
final class HarnessCatalogRefresher {
  static let retryDelays: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]

  private let cache: ConfigOptionCache
  private let clock: any Clock<Duration>
  private var refetches: [String: Task<Void, Never>] = [:]

  init(cache: ConfigOptionCache, clock: any Clock<Duration> = ContinuousClock()) {
    self.cache = cache
    self.clock = clock
  }

  func refetch(forServer serverId: String, client: any CodevisorServerClienting) {
    refetches[serverId]?.cancel()
    refetches[serverId] = nil
    guard cache.hasCatalog(forServer: serverId) else { return }

    let target = Target(serverId: serverId, cwd: cache.catalogCwd(forServer: serverId), client: client)
    refetches[serverId] = Task { await self.refetchCatalog(target) }
  }

  private struct Target {
    let serverId: String
    let cwd: String
    let client: any CodevisorServerClienting
  }

  private func refetchCatalog(_ target: Target) async {
    let catalog = try? await cache.revalidateCapabilities(
      forServer: target.serverId, cwd: target.cwd, client: target.client, force: true)
    guard let catalog else { return }

    var failing = Self.failedHarnessIds(in: catalog)
    for delay in Self.retryDelays where !failing.isEmpty {
      guard (try? await clock.sleep(for: delay)) != nil else { return }
      failing = await retry(failing, target)
    }
    guard failing.isEmpty, !Task.isCancelled else { return }

    cache.noteCatalogComplete(forServer: target.serverId)
  }

  private func retry(_ harnessIds: [String], _ target: Target) async -> [String] {
    var failing: [String] = []
    for harnessId in harnessIds {
      let capability = await inspect(harnessId, target)
      guard !Task.isCancelled else { return harnessIds }
      guard let capability, capability.inspectionFailed != true else {
        failing.append(harnessId)
        continue
      }

      if Self.isUsable(capability) { cache.store(capability, forServer: target.serverId) }
    }
    return failing
  }

  private func inspect(_ harnessId: String, _ target: Target) async -> ServerHarnessCapability? {
    let response = try? await target.client.capabilities(cwd: target.cwd, harnessId: harnessId)
    return response?.harnesses.first { $0.harness.id == harnessId }
  }

  private static func failedHarnessIds(in catalog: [ServerHarnessCapability]) -> [String] {
    catalog.filter { $0.inspectionFailed == true }.map(\.harness.id)
  }

  private static func isUsable(_ capability: ServerHarnessCapability) -> Bool {
    capability.harness.enabled && capability.harness.isReady
  }
}

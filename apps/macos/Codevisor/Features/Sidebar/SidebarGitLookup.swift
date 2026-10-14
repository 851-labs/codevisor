import CodevisorClient
import Foundation

@MainActor
@Observable
final class SidebarGitLookup<Value: Equatable & Sendable> {
  struct Target: Sendable {
    let workspaceId: UUID
    let path: String
    let client: any CodevisorServerClienting
  }

  typealias Fetch = @Sendable (any CodevisorServerClienting, String) async throws -> Value?

  let refreshInterval: Duration
  private(set) var byWorkspace: [UUID: Value] = [:]
  @ObservationIgnored private let fetch: Fetch
  @ObservationIgnored private var lastAsked: [UUID: (path: String, at: ContinuousClock.Instant)] = [:]
  @ObservationIgnored private var inFlight: Set<UUID> = []
  @ObservationIgnored private let clock = ContinuousClock()

  init(refreshInterval: Duration, fetch: @escaping Fetch) {
    self.refreshInterval = refreshInterval
    self.fetch = fetch
  }

  func refresh(_ targets: [Target]) {
    let now = clock.now
    for target in targets where !inFlight.contains(target.workspaceId) {
      if let last = lastAsked[target.workspaceId], last.path == target.path,
        now - last.at < refreshInterval
      {
        continue
      }
      inFlight.insert(target.workspaceId)
      let fetch = fetch
      Task { [weak self] in
        let value = (try? await fetch(target.client, target.path)) ?? nil
        self?.record(value, for: target)
      }
    }
  }

  private func record(_ value: Value?, for target: Target) {
    inFlight.remove(target.workspaceId)
    lastAsked[target.workspaceId] = (target.path, clock.now)
    if byWorkspace[target.workspaceId] != value {
      byWorkspace[target.workspaceId] = value
    }
  }
}

extension SidebarGitLookup where Value == ServerGitPullRequest {
  static func pullRequests() -> SidebarGitLookup {
    SidebarGitLookup(refreshInterval: .seconds(180)) { client, path in
      try await client.gitPullRequest(path: path)
    }
  }
}

extension SidebarGitLookup where Value == String {
  static func branches() -> SidebarGitLookup {
    SidebarGitLookup(refreshInterval: .seconds(60)) { client, path in
      try await client.gitRefs(path: path).currentBranch
    }
  }
}

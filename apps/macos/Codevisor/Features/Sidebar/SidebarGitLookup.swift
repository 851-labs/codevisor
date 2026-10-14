import CodevisorClient
import Foundation

/// One git fact about each of the sidebar's workspaces (its pull request,
/// its branch), asked of the workspace's own machine, where its checkout
/// lives. One per window and fact; filled only while the sidebar shows it,
/// and each workspace is asked again at most once per `refreshInterval`.
@MainActor
@Observable
final class SidebarGitLookup<Value: Equatable & Sendable> {
  /// A workspace to ask about: its checkout on its machine.
  struct Target: Sendable {
    let workspaceId: UUID
    let path: String
    let client: any CodevisorServerClienting
  }

  typealias Fetch = @Sendable (any CodevisorServerClienting, String) async throws -> Value?

  /// How long an answer stands before the workspace is asked again.
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

  /// Asks about every target whose answer is missing or stale. A failure
  /// (an older server, an unreachable machine) counts as "none" until the
  /// next interval, so nothing is retried in a tight loop.
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
  /// The pull request for each workspace's branch, from its machine's `gh`
  /// (which knows the user's GitHub account). A GitHub round trip, so asked
  /// every few minutes.
  static func pullRequests() -> SidebarGitLookup {
    SidebarGitLookup(refreshInterval: .seconds(180)) { client, path in
      try await client.gitPullRequest(path: path)
    }
  }
}

extension SidebarGitLookup where Value == String {
  /// The branch each workspace's checkout is on; nil while HEAD is
  /// detached. Local git on its machine, so asked every minute to follow
  /// checkouts.
  static func branches() -> SidebarGitLookup {
    SidebarGitLookup(refreshInterval: .seconds(60)) { client, path in
      try await client.gitRefs(path: path).currentBranch
    }
  }
}

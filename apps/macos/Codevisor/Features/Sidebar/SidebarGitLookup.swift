import CodevisorClient
import Foundation

enum SidebarGitLookupSource: Equatable, Sendable {
  case checkout(path: String)
  case archived
}

@MainActor
@Observable
final class SidebarGitLookup<Value: Equatable & Sendable> {
  struct Target: Sendable {
    let workspaceId: UUID
    let source: SidebarGitLookupSource
    let client: any CodevisorServerClienting
  }

  typealias Fetch = @Sendable (Target) async throws -> Value?

  let refreshInterval: Duration
  private(set) var byWorkspace: [UUID: Value] = [:]
  @ObservationIgnored private let fetch: Fetch
  @ObservationIgnored private var lastAsked: [UUID: (source: SidebarGitLookupSource, at: ContinuousClock.Instant)] = [:]
  @ObservationIgnored private var inFlight: Set<UUID> = []
  @ObservationIgnored private let clock = ContinuousClock()

  init(refreshInterval: Duration, fetch: @escaping Fetch) {
    self.refreshInterval = refreshInterval
    self.fetch = fetch
  }

  func refresh(_ targets: [Target]) {
    let now = clock.now
    for target in targets where !inFlight.contains(target.workspaceId) {
      if let last = lastAsked[target.workspaceId], last.source == target.source,
        target.source == .archived || now - last.at < refreshInterval
      {
        continue
      }
      inFlight.insert(target.workspaceId)
      let fetch = fetch
      Task { [weak self] in
        let value = (try? await fetch(target)) ?? nil
        self?.record(value, for: target)
      }
    }
  }

  private func record(_ value: Value?, for target: Target) {
    inFlight.remove(target.workspaceId)
    lastAsked[target.workspaceId] = (target.source, clock.now)
    if byWorkspace[target.workspaceId] != value {
      byWorkspace[target.workspaceId] = value
    }
  }
}

extension SidebarGitLookup where Value == ServerGitPullRequest {
  static func pullRequests() -> SidebarGitLookup {
    SidebarGitLookup(refreshInterval: .seconds(180)) { target in
      switch target.source {
      case let .checkout(path): try await target.client.gitPullRequest(path: path)
      case .archived: try await target.client.workspaceGitPullRequest(workspaceId: target.workspaceId)
      }
    }
  }
}

extension SidebarGitLookup where Value == String {
  static func branches() -> SidebarGitLookup {
    SidebarGitLookup(refreshInterval: .seconds(60)) { target in
      switch target.source {
      case let .checkout(path): try await target.client.gitRefs(path: path).currentBranch
      case .archived: try await target.client.workspaceGitBranch(workspaceId: target.workspaceId)
      }
    }
  }
}

import CodevisorCore
import Foundation

public enum SidebarGitLookupSource: Equatable, Sendable {
  case checkout(path: String)
  case archived
}

@MainActor
@Observable
public final class SidebarGitLookup<Value: Equatable & Sendable> {
  public struct Target: Sendable {
    let workspaceId: UUID
    let source: SidebarGitLookupSource
    let client: any CodevisorServerClienting
  }

  public typealias Fetch = @Sendable (Target) async throws -> Value?

  let refreshInterval: Duration
  public private(set) var byWorkspace: [UUID: Value] = [:]
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

@MainActor
public final class SidebarGitLookups {
  public struct RefreshKey: Equatable {
    let pullRequests: Bool
    let branches: Bool
    let workspaceIds: [UUID]
  }

  public let pullRequests = SidebarGitLookup.pullRequests()
  public let branches = SidebarGitLookup.branches()

  public init() {}

  public static func refreshKey(details: [SidebarRowDetail], workspaceIds: [UUID]) -> RefreshKey? {
    let pullRequests = details.contains(.pullRequest)
    let branches = details.contains(.branch)
    guard pullRequests || branches else { return nil }
    return RefreshKey(pullRequests: pullRequests, branches: branches, workspaceIds: workspaceIds)
  }

  public func refresh(
    active: [Workspace],
    archived: [Workspace],
    details: [SidebarRowDetail],
    client: (String) -> any CodevisorServerClienting
  ) {
    let sources =
      active.compactMap { workspace -> (Workspace, SidebarGitLookupSource)? in
        guard let path = workspace.rootDirectory, !path.isEmpty else { return nil }
        return (workspace, .checkout(path: path))
      }
      + archived.compactMap { workspace in
        workspace.rootDirectory?.isEmpty == false ? (workspace, .archived) : nil
      }
    func targets<Value>() -> [SidebarGitLookup<Value>.Target] {
      sources.map { workspace, source in
        .init(workspaceId: workspace.id, source: source, client: client(workspace.serverId))
      }
    }
    if details.contains(.pullRequest) {
      pullRequests.refresh(targets())
    }
    if details.contains(.branch) {
      branches.refresh(targets())
    }
  }
}

import CodevisorCore
import Foundation

@MainActor
@Observable
public final class SidebarGitLookup<Request: Equatable & Sendable, Value: Equatable & Sendable> {
  public struct Target: Sendable {
    let workspaceId: UUID
    let request: Request
    let client: any CodevisorServerClienting

    public init(workspaceId: UUID, request: Request, client: any CodevisorServerClienting) {
      self.workspaceId = workspaceId
      self.request = request
      self.client = client
    }
  }

  public typealias Fetch = @Sendable (Target) async throws -> Value?
  public typealias Answers = (_ asked: Request, _ wanted: Request) -> Bool

  let refreshInterval: Duration?
  public private(set) var byWorkspace: [UUID: Value] = [:]
  @ObservationIgnored private let answers: Answers
  @ObservationIgnored private let fetch: Fetch
  @ObservationIgnored private var lastAsked: [UUID: (request: Request, at: ContinuousClock.Instant)] = [:]
  @ObservationIgnored private var inFlight: Set<UUID> = []
  @ObservationIgnored private let clock = ContinuousClock()

  init(refreshInterval: Duration?, answers: @escaping Answers = { $0 == $1 }, fetch: @escaping Fetch) {
    self.refreshInterval = refreshInterval
    self.answers = answers
    self.fetch = fetch
  }

  public func refresh(_ targets: [Target]) {
    let now = clock.now
    for target in targets where !inFlight.contains(target.workspaceId) {
      if let last = lastAsked[target.workspaceId], answers(last.request, target.request),
        refreshInterval.map({ now - last.at < $0 }) ?? true
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

  public func forget(_ workspaceIds: [UUID]) {
    for id in workspaceIds where lastAsked[id] != nil {
      lastAsked[id] = nil
      byWorkspace[id] = nil
    }
  }

  private func record(_ value: Value?, for target: Target) {
    inFlight.remove(target.workspaceId)
    lastAsked[target.workspaceId] = (target.request, clock.now)
    if byWorkspace[target.workspaceId] != value {
      byWorkspace[target.workspaceId] = value
    }
  }
}

extension SidebarGitLookup where Request == String, Value == ServerGitPullRequest {
  static func pullRequests() -> SidebarGitLookup {
    SidebarGitLookup(refreshInterval: .seconds(180)) { target in
      try await target.client.gitPullRequest(path: target.request)
    }
  }
}

extension SidebarGitLookup where Request == String, Value == String {
  static func branches() -> SidebarGitLookup {
    SidebarGitLookup(refreshInterval: .seconds(60)) { target in
      try await target.client.gitRefs(path: target.request).currentBranch
    }
  }
}

extension SidebarGitLookup where Request == Bool, Value == ServerWorkspaceGit {
  static func archived() -> SidebarGitLookup {
    SidebarGitLookup(refreshInterval: nil, answers: { asked, wanted in asked || !wanted }) { target in
      try await target.client.workspaceGit(workspaceId: target.workspaceId, includePullRequest: target.request)
    }
  }
}

@MainActor
public final class SidebarGitLookups {
  public struct RefreshKey: Equatable {
    let pullRequests: Bool
    let branches: Bool
    let workspaceIds: [UUID]
    let archivedWorkspaceIds: [UUID]
  }

  public let pullRequests = SidebarGitLookup.pullRequests()
  public let branches = SidebarGitLookup.branches()
  public let archivedGit = SidebarGitLookup.archived()

  public init() {}

  public static func refreshKey(
    details: [SidebarRowDetail], workspaceIds: [UUID], archivedWorkspaceIds: [UUID]
  ) -> RefreshKey? {
    let pullRequests = details.contains(.pullRequest)
    let branches = details.contains(.branch)
    guard pullRequests || branches else { return nil }
    return RefreshKey(
      pullRequests: pullRequests, branches: branches, workspaceIds: workspaceIds,
      archivedWorkspaceIds: archivedWorkspaceIds)
  }

  public func branch(for workspace: Workspace) -> String? {
    if let git = workspace.git { return git.branch }
    if workspace.isArchived, let archived = archivedGit.byWorkspace[workspace.id] { return archived.branch }
    return branches.byWorkspace[workspace.id]
  }

  public func pullRequest(for workspace: Workspace) -> ServerGitPullRequest? {
    if let git = workspace.git { return git.pullRequest }
    if workspace.isArchived, let archived = archivedGit.byWorkspace[workspace.id] { return archived.pullRequest }
    return pullRequests.byWorkspace[workspace.id]
  }

  public func refresh(
    active: [Workspace],
    archived: [Workspace],
    listedIds: [UUID],
    details: [SidebarRowDetail],
    client: (String) -> any CodevisorServerClienting
  ) {
    func targets<Request, Value>(_ requests: [(Workspace, Request)]) -> [SidebarGitLookup<Request, Value>.Target] {
      requests.map { workspace, request in
        .init(workspaceId: workspace.id, request: request, client: client(workspace.serverId))
      }
    }
    let checkouts = active.compactMap { workspace -> (Workspace, String)? in
      guard workspace.git == nil, let path = workspace.rootDirectory, !path.isEmpty else { return nil }
      return (workspace, path)
    }
    let wantsPullRequests = details.contains(.pullRequest)
    if wantsPullRequests {
      pullRequests.refresh(targets(checkouts))
    }
    if details.contains(.branch) {
      branches.refresh(targets(checkouts))
    }
    archivedGit.forget(listedIds)
    let archivedCheckouts = archived.filter { $0.git == nil && $0.rootDirectory?.isEmpty == false }
    archivedGit.refresh(targets(archivedCheckouts.map { ($0, wantsPullRequests) }))
  }
}

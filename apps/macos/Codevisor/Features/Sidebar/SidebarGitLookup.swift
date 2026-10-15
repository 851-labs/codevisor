import CodevisorClient
import Foundation

@MainActor
@Observable
final class SidebarGitLookup<Request: Equatable & Sendable, Value: Equatable & Sendable> {
  struct Target: Sendable {
    let workspaceId: UUID
    let request: Request
    let client: any CodevisorServerClienting
  }

  typealias Fetch = @Sendable (Target) async throws -> Value?
  typealias Answers = (_ asked: Request, _ wanted: Request) -> Bool

  let refreshInterval: Duration?
  private(set) var byWorkspace: [UUID: Value] = [:]
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

  func refresh(_ targets: [Target]) {
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

  func forget(_ workspaceIds: [UUID]) {
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

import CodevisorClient
import Foundation

/// The pull requests behind the sidebar's workspaces, asked of each
/// workspace's own machine (whose `gh` knows the user's GitHub account).
/// One per window; filled only while the sidebar shows PRs, and each
/// workspace is asked again at most every few minutes.
@MainActor
@Observable
final class SidebarPullRequests {
  /// A workspace to ask about: its checkout on its machine.
  struct Target: Sendable {
    let workspaceId: UUID
    let path: String
    let client: any CodevisorServerClienting
  }

  /// How long an answer stands before the workspace is asked again.
  static let refreshInterval: Duration = .seconds(180)

  private(set) var byWorkspace: [UUID: ServerGitPullRequest] = [:]
  @ObservationIgnored private var lastAsked: [UUID: (path: String, at: ContinuousClock.Instant)] = [:]
  @ObservationIgnored private var inFlight: Set<UUID> = []
  @ObservationIgnored private let clock = ContinuousClock()

  /// Asks about every target whose answer is missing or stale. A failure
  /// (an older server, an unreachable machine) counts as "no pull request"
  /// until the next interval, so nothing is retried in a tight loop.
  func refresh(_ targets: [Target]) {
    let now = clock.now
    for target in targets where !inFlight.contains(target.workspaceId) {
      if let last = lastAsked[target.workspaceId], last.path == target.path,
        now - last.at < Self.refreshInterval
      {
        continue
      }
      inFlight.insert(target.workspaceId)
      Task { [weak self] in
        let pullRequest = (try? await target.client.gitPullRequest(path: target.path)) ?? nil
        self?.record(pullRequest, for: target)
      }
    }
  }

  private func record(_ pullRequest: ServerGitPullRequest?, for target: Target) {
    inFlight.remove(target.workspaceId)
    lastAsked[target.workspaceId] = (target.path, clock.now)
    if byWorkspace[target.workspaceId] != pullRequest {
      byWorkspace[target.workspaceId] = pullRequest
    }
  }
}

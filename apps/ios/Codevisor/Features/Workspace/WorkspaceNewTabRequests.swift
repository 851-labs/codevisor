import Foundation
import Observation

/// New tabs asked for from a workspace's page, waiting for that workspace's
/// tab screen to open them: the page has no pane state of its own, and the
/// screen may be about to mount (a push) or already showing (beside the
/// page on iPad). The screen takes its request once.
@MainActor
@Observable
final class WorkspaceNewTabRequests {
  static let shared = WorkspaceNewTabRequests()

  private(set) var pending: [UUID: NewTabChoice] = [:]

  func request(_ choice: NewTabChoice, in workspaceId: UUID) {
    pending[workspaceId] = choice
  }

  func take(for workspaceId: UUID) -> NewTabChoice? {
    pending.removeValue(forKey: workspaceId)
  }
}

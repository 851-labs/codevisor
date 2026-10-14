import Foundation

/// Optional details a workspace row can show, chosen in the sidebar's
/// Properties menu. A per-device preference.
enum SidebarRowDetail: String, CaseIterable, Codable, Identifiable {
  /// How long ago the workspace's chats last changed.
  case updated
  /// The pull request for the workspace's branch, from its machine's `gh`.
  case pullRequest
  /// The machine the workspace runs on, as its glyph.
  case machine
  /// The workspace's project, on the row's second line.
  case project
  /// The branch its checkout is on, from its machine's git, on the second
  /// line.
  case branch

  static let preferenceKey = "sidebar.rowDetails"
  static let defaults: [SidebarRowDetail] = [.updated, .pullRequest, .machine, .project]

  /// The details after the row's name.
  static let trailingDetails: [SidebarRowDetail] = [.updated, .pullRequest, .machine]
  /// The details on the row's second line, in the order they read.
  static let subtitleDetails: [SidebarRowDetail] = [.project, .branch]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .updated: "Updated"
    case .pullRequest: "PR"
    case .machine: "Machine"
    case .project: "Project"
    case .branch: "Branch"
    }
  }

  var systemImage: String {
    switch self {
    case .updated: "clock"
    case .pullRequest: "arrow.triangle.pull"
    case .machine: "desktopcomputer"
    case .project: "folder"
    case .branch: "arrow.triangle.branch"
    }
  }
}

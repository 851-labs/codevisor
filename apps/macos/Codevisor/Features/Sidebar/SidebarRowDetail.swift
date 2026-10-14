import Foundation

/// Optional details a workspace row can show, chosen in the sidebar's Show
/// menu. A per-device preference.
enum SidebarRowDetail: String, CaseIterable, Codable, Identifiable {
  /// How long ago the workspace's chats last changed.
  case updated
  /// The pull request for the workspace's branch, from its machine's `gh`.
  case pullRequest

  static let preferenceKey = "sidebar.rowDetails"
  static let defaults: [SidebarRowDetail] = [.updated, .pullRequest]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .updated: "Updated"
    case .pullRequest: "PR"
    }
  }

  var systemImage: String {
    switch self {
    case .updated: "clock"
    case .pullRequest: "arrow.triangle.pull"
    }
  }
}

import Foundation

enum SidebarRowDetail: String, CaseIterable, Codable, Identifiable {
  case pullRequest
  case machine
  case project
  case branch

  static let preferenceKey = "sidebar.rowDetails"
  static let defaults: [SidebarRowDetail] = [.pullRequest, .machine, .project, .branch]

  static let trailingDetails: [SidebarRowDetail] = [.pullRequest, .machine]
  static let subtitleDetails: [SidebarRowDetail] = [.project, .branch]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .pullRequest: "PR"
    case .machine: "Machine"
    case .project: "Project"
    case .branch: "Branch"
    }
  }

  var systemImage: String {
    switch self {
    case .pullRequest: "arrow.triangle.pull"
    case .machine: "desktopcomputer"
    case .project: "folder"
    case .branch: "arrow.triangle.branch"
    }
  }
}

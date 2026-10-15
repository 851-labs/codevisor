import Foundation

public enum SidebarRowDetail: String, CaseIterable, Codable, Identifiable, Sendable {
  case pullRequest
  case machine
  case project
  case branch

  public static let preferenceKey = "sidebar.rowDetails"
  public static let defaults: [SidebarRowDetail] = [.pullRequest, .machine, .project, .branch]

  public static let trailingDetails: [SidebarRowDetail] = [.pullRequest, .machine]
  public static let subtitleDetails: [SidebarRowDetail] = [.project, .branch]

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .pullRequest: "PR"
    case .machine: "Machine"
    case .project: "Project"
    case .branch: "Branch"
    }
  }

  public var systemImage: String {
    switch self {
    case .pullRequest: "arrow.triangle.pull"
    case .machine: "desktopcomputer"
    case .project: "folder"
    case .branch: "arrow.triangle.branch"
    }
  }
}

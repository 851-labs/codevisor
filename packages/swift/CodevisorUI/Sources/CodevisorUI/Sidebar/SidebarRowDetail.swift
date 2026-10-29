import CodevisorCore
import Foundation
import SwiftUI

public enum SidebarRowDetail: String, CaseIterable, Codable, Identifiable, Sendable {
  case pullRequest
  case machine
  case project
  case branch
  case worktree

  public static let legacyPreferenceKey = "sidebar.rowDetails"
  public static let preferenceKeys = allCases.map(\.preferenceKey) + [legacyPreferenceKey]
  public static let defaults = allCases.filter(\.isShownByDefault)

  public static let trailingDetails: [SidebarRowDetail] = [.pullRequest, .machine]
  public static let subtitleDetails: [SidebarRowDetail] = [.project, .branch, .worktree]

  public var id: String { rawValue }

  public var preferenceKey: String { "sidebar.rowDetail.\(rawValue)" }

  public var isShownByDefault: Bool { self != .worktree }

  public var title: String {
    switch self {
    case .pullRequest: "PR"
    case .machine: "Machine"
    case .project: "Project"
    case .branch: "Branch"
    case .worktree: "Worktree"
    }
  }

  public var icon: Image {
    switch self {
    case .pullRequest: Image(systemName: "arrow.triangle.pull")
    case .machine: Image(systemName: "desktopcomputer")
    case .project: Image(systemName: "folder")
    case .branch: CodevisorSymbol.gitBranch.image
    case .worktree: Image(systemName: CodevisorSymbol.worktreeSystemName)
    }
  }
}

extension ClientPreferences {
  public var sidebarRowDetails: [SidebarRowDetail] {
    SidebarRowDetail.allCases.filter(isSidebarRowDetailShown)
  }

  public func isSidebarRowDetailShown(_ detail: SidebarRowDetail) -> Bool {
    valueIfPresent(forKey: detail.preferenceKey, as: Bool.self)
      ?? valueIfPresent(forKey: SidebarRowDetail.legacyPreferenceKey, as: [SidebarRowDetail].self)?.contains(detail)
      ?? detail.isShownByDefault
  }

  public func setSidebarRowDetail(_ detail: SidebarRowDetail, shown: Bool) {
    set(shown, forKey: detail.preferenceKey)
  }
}

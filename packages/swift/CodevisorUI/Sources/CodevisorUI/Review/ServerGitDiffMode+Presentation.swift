import CodevisorCore
import SwiftUI

extension ServerGitDiffMode {
  public static let reviewOrder: [ServerGitDiffMode] = [.branch, .uncommitted, .staged, .unstaged, .lastTurn]

  public var title: String {
    switch self {
    case .branch: "Branch"
    case .uncommitted: "Uncommitted"
    case .staged: "Staged"
    case .unstaged: "Unstaged"
    case .lastTurn: "Last Turn"
    }
  }

  public var icon: Image {
    switch self {
    case .branch: CodevisorSymbol.gitBranch.image
    case .uncommitted: Image(systemName: "pencil.line")
    case .staged: Image(systemName: "tray.and.arrow.down")
    case .unstaged: Image(systemName: "circle.dashed")
    case .lastTurn: Image(systemName: "clock.arrow.circlepath")
    }
  }

  func summary(base: String) -> String {
    switch self {
    case .branch: "All changes since this branch left \(base), including uncommitted work."
    case .uncommitted: "Changes not yet committed, staged or not."
    case .staged: "Changes staged for the next commit."
    case .unstaged: "Changes not yet staged."
    case .lastTurn: "Changes made since the latest agent turn started."
    }
  }

  var emptyTitle: String {
    switch self {
    case .branch: "No Changes on This Branch"
    case .uncommitted: "No Uncommitted Changes"
    case .staged: "No Staged Changes"
    case .unstaged: "No Unstaged Changes"
    case .lastTurn: "No Changes Since the Last Turn"
    }
  }
}

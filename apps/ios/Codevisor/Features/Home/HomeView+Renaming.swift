import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// The agent list's edits that Home owns: renames, and the reflow they
/// animate with.
extension HomeView {
  /// Chat labels belong to the shared session record.
  func renameSidebarTab(_ request: HomeTabRenameRequest, to title: String) {
    environment.workspaceSync.renameTab(
      workspaceId: request.workspaceId, tabId: request.tabId, chatSessionId: request.chatSessionId, to: title
    )
  }

  func renameWorkspace(_ renamed: Workspace) {
    withSidebarReflow {
      environment.workspaceSync.renameWorkspace(
        renamed, client: environment.machines.client(for: renamed.serverId)
      )
    }
  }

  /// A local sidebar edit: the entries it touches update synchronously, so
  /// the resulting row reflow animates with it.
  func withSidebarReflow(_ change: () -> Void) {
    withAnimation(Motion.listReflow(reduceMotion: reduceMotion), change)
  }
}

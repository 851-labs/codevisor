import CodevisorCore
import SwiftUI

/// What a workspace or tab row asks Home to do, wherever the row is: the
/// root list or a workspace's page. Home owns navigation and the rename
/// alert, so rows reach it through the environment.
struct WorkspaceRowActions {
  /// Shows a workspace's page: pushed on a phone, selected beside a sidebar.
  var openPage: @MainActor (_ serverId: String, _ workspaceId: UUID) -> Void = { _, _ in }
  /// Shows a folder's page, the same way.
  var openFolder: @MainActor (UUID) -> Void = { _ in }
  /// Opens a tab through its workspace's page.
  var openTab: @MainActor (HomeRoute) -> Void = { _ in }
  var rename: @MainActor (UUID) -> Void = { _ in }
  var archive: @MainActor (UUID) -> Void = { _ in }
}

extension EnvironmentValues {
  @Entry var workspaceRowActions = WorkspaceRowActions()
}

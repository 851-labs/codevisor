import CodevisorCore

enum WorkspaceLayoutPolicy {
  static func isTabless(_ workspace: Workspace, environment: AppEnvironment) -> Bool {
    environment.bots.ownsWorkspace(workspace)
  }

  static func isSplit(_ workspace: Workspace, environment: AppEnvironment) -> Bool {
    workspace.centerTree.allGroups.count - environment.leavesCoveredByBotPage(in: workspace).count > 1
  }

  static func showsTitlebarDivider(_ workspace: Workspace, environment: AppEnvironment) -> Bool {
    !isTabless(workspace, environment: environment) || isSplit(workspace, environment: environment)
  }
}

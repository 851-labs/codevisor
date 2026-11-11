import CodevisorCore

enum WorkspaceLayoutPolicy {
  static func isTabless(_ workspace: Workspace, environment: AppEnvironment) -> Bool {
    guard FeatureFlag.bots.isEnabled else { return false }

    return environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId) != nil
  }

  static func isSplit(_ workspace: Workspace) -> Bool {
    workspace.centerTree.allGroups.count > 1
  }

  static func showsTitlebarDivider(_ workspace: Workspace, environment: AppEnvironment) -> Bool {
    !isTabless(workspace, environment: environment) || isSplit(workspace)
  }
}

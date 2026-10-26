import CodevisorCore

enum WorkspaceLayoutPolicy {
  static func isSinglePane(_ workspace: Workspace, environment: AppEnvironment) -> Bool {
    guard FeatureFlag.bots.isEnabled else { return false }

    return environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId) != nil
  }
}

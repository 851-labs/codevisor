import CodevisorCore
import Foundation

enum WorkspaceLayoutPolicy {
  static func isTabless(_ workspace: Workspace, environment: AppEnvironment) -> Bool {
    environment.bots.ownsWorkspace(workspace)
  }

  static func usesBotChrome(_ workspace: Workspace, environment: AppEnvironment) -> Bool {
    isTabless(workspace, environment: environment) && environment.botPages.agentPage(in: workspace) == nil
  }

  static func leavesCoveredByBotPage(in workspace: Workspace, environment: AppEnvironment) -> Set<UUID> {
    guard let bot = environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId),
      environment.botPages.page(of: bot) != .conversation,
      let conversation = workspace.centerTree.groupId(containingChat: bot.sessionId)
    else { return [] }
    return Set(workspace.centerTree.allGroups.map(\.id)).subtracting([conversation])
  }

  static func isSplit(_ workspace: Workspace, environment: AppEnvironment) -> Bool {
    let covered = leavesCoveredByBotPage(in: workspace, environment: environment)
    return workspace.centerTree.allGroups.count - covered.count > 1
  }

  static func showsTitlebarDivider(_ workspace: Workspace, environment: AppEnvironment) -> Bool {
    !usesBotChrome(workspace, environment: environment) || isSplit(workspace, environment: environment)
  }
}

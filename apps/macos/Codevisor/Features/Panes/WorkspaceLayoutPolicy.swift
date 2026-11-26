import CodevisorCore
import Foundation

enum WorkspaceLayoutPolicy {
  static func isTabless(_ workspace: Workspace, environment: AppEnvironment) -> Bool {
    environment.bots.ownsWorkspace(workspace)
  }

  static func usesBotChrome(_ page: BotPage?) -> Bool {
    guard let page else { return false }

    return page.agent == nil
  }

  static func leavesCovered(
    by page: BotPage?, in workspace: Workspace, environment: AppEnvironment
  ) -> Set<UUID> {
    guard let page, page != .conversation,
      let bot = environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId),
      let conversation = workspace.centerTree.groupId(containingChat: bot.sessionId)
    else { return [] }
    return Set(workspace.centerTree.allGroups.map(\.id)).subtracting([conversation])
  }

  static func isSplit(_ workspace: Workspace, showing page: BotPage?, environment: AppEnvironment) -> Bool {
    let covered = leavesCovered(by: page, in: workspace, environment: environment)
    return workspace.centerTree.allGroups.count - covered.count > 1
  }

  static func showsTitlebarDivider(
    _ workspace: Workspace, showing page: BotPage?, environment: AppEnvironment
  ) -> Bool {
    !usesBotChrome(page) || isSplit(workspace, showing: page, environment: environment)
  }
}

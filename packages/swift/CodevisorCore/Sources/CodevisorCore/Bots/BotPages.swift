import Foundation

public enum BotPage: Equatable {
  case conversation
  case thread(ServerThread)
  case agent(ChatSession, in: Project)

  public var agent: ChatSession? {
    guard case let .agent(agent, _) = self else { return nil }
    return agent
  }
}

@MainActor
public struct BotPages {
  let threads: BotThreadsModel
  let hosts: ChatHosts

  public init(threads: BotThreadsModel, hosts: ChatHosts) {
    self.threads = threads
    self.hosts = hosts
  }

  public func page(of bot: Bot) -> BotPage {
    if let thread = threads.openThread(of: bot) { return .thread(thread) }
    if let agent = openAgent(of: bot), let project = project(of: agent) { return .agent(agent, in: project) }
    return .conversation
  }

  public func agentPage(in workspace: Workspace) -> ChatSession? {
    guard let bot = hosts.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId) else { return nil }

    return page(of: bot).agent
  }

  @discardableResult
  public func show(_ chat: ChatSession) -> Bot? {
    if let bot = hosts.bots.bot(forSession: chat.id, serverId: chat.serverId) {
      threads.closePage(of: bot)
      return bot
    }
    guard let bot = hosts.botShowing(chat) else { return nil }

    threads.showAgent(chat.id, of: bot)
    return bot
  }

  private func openAgent(of bot: Bot) -> ChatSession? {
    guard let id = threads.openAgent(of: bot),
      let chat = hosts.projectList.chat(id, preferring: bot.serverId), !chat.isArchived
    else { return nil }
    return chat
  }

  private func project(of chat: ChatSession) -> Project? {
    hosts.projectList.projects.first { $0.serverId == chat.serverId && $0.id == chat.projectId }
  }
}

extension AppEnvironment {
  public var botPages: BotPages {
    BotPages(threads: botThreads, hosts: chatHosts)
  }
}

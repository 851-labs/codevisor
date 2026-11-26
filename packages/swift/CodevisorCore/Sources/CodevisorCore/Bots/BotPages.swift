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
  let resolver: PaneChatResolver

  public init(threads: BotThreadsModel, hosts: ChatHosts, resolver: PaneChatResolver) {
    self.threads = threads
    self.hosts = hosts
    self.resolver = resolver
  }

  public func page(of bot: Bot) -> BotPage {
    if let thread = threads.openThread(of: bot), isListed(bot) { return .thread(thread) }
    if let agent = openAgent(of: bot), let project = project(of: agent) { return .agent(agent, in: project) }
    return .conversation
  }

  public func page(in workspace: Workspace) -> BotPage? {
    hosts.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId).map(page(of:))
  }

  public func agentPage(in workspace: Workspace) -> ChatSession? {
    page(in: workspace)?.agent
  }

  @discardableResult
  public func show(_ chat: ChatSession) -> Bot? {
    if let bot = hosts.bots.bot(forSession: chat.id, serverId: chat.serverId) {
      threads.closeAgent(of: bot)
      return bot
    }
    guard let bot = hosts.botShowing(chat) else { return nil }

    threads.showAgent(chat.id, of: bot)
    return bot
  }

  public func hasGoneAgent(_ bot: Bot) -> Bool {
    guard let id = threads.openAgent(of: bot) else { return false }
    if let chat = hosts.projectList.chat(id, preferring: bot.serverId) { return chat.isArchived }

    return resolver.chat(id, on: bot.serverId) == .missing
  }

  public func forgetGoneAgent(of bot: Bot) {
    guard hasGoneAgent(bot) else { return }

    threads.closeAgent(of: bot)
  }

  private func isListed(_ bot: Bot) -> Bool {
    hosts.projectList.chat(bot.sessionId, preferring: bot.serverId).flatMap(project(of:)) != nil
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
    BotPages(
      threads: botThreads, hosts: chatHosts, resolver: PaneChatResolver(projectList: projectList, machines: machines))
  }
}

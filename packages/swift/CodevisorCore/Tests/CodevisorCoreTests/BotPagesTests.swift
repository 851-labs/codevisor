import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Bot pages", .timeLimit(.minutes(1)))
struct BotPagesTests {
  let botProject = Project.fromFolder(URL(fileURLWithPath: "/bots/helper"), serverId: "local")
  let appProject = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "local")

  @Test("A bot shows its conversation until one of its agents opens, as a page of the bot's own workspace")
  func agentOpensInPlaceOfTheConversation() async throws {
    let world = try await BotWorld(botProject: botProject)
    let agent = world.chat("Christmas list", in: appProject, createdBy: world.botChat)
    let pages = try await world.pages(projects: [appProject], sessions: [agent])
    let elsewhere = world.workspace(agent, in: appProject)

    #expect(pages.page(of: world.bot) == .conversation)
    #expect(pages.agentPage(in: world.botWorkspace()) == nil)

    #expect(pages.show(agent) == world.bot)

    #expect(pages.page(of: world.bot).agent?.id == agent.id)
    #expect(pages.agentPage(in: world.botWorkspace())?.id == agent.id)
    #expect(pages.agentPage(in: elsewhere) == nil)
  }

  @Test("Opening the bot's own conversation closes its agent's page and leaves an open thread alone")
  func conversationClosesOnlyTheAgentPage() async throws {
    let world = try await BotWorld(botProject: botProject)
    let agent = world.chat("Christmas list", in: appProject, createdBy: world.botChat)
    let pages = try await world.pages(projects: [appProject], sessions: [agent])
    pages.show(agent)

    #expect(pages.show(world.botChat) == world.bot)
    #expect(pages.page(of: world.bot) == .conversation)

    await world.openThread("t1")
    pages.show(world.botChat)

    #expect(world.threads.openThread(of: world.bot)?.threadId == "t1")
  }

  @Test("A thread is the bot's page only while the bot's own chat is loaded to draw it in")
  func threadNeedsTheBotsChat() async throws {
    let world = try await BotWorld(botProject: botProject)
    let pages = try await world.pages(projects: [], sessions: [])
    await world.openThread("t1")

    #expect(pages.page(of: world.bot) == .thread(try #require(world.threads.openThread(of: world.bot))))

    await world.navigation.install(projects: [], sessions: [], workspaces: [world.botWorkspace()])

    #expect(pages.page(of: world.bot) == .conversation)
  }

  @Test("An agent's own helper opens as the bot's page, and a chat no bot started opens in no bot")
  func onlyTheBotsAgentsOpenInIt() async throws {
    let world = try await BotWorld(botProject: botProject)
    let agent = world.chat("Christmas list", in: appProject, createdBy: world.botChat)
    let helper = world.chat("Price checker", in: appProject, createdBy: agent)
    let stray = world.chat("Stray", in: appProject)
    let pages = try await world.pages(projects: [appProject], sessions: [agent, helper, stray])

    #expect(pages.show(helper) == world.bot)
    #expect(pages.show(stray) == nil)

    #expect(pages.page(of: world.bot).agent?.id == helper.id)
  }

  @Test("An agent the bot started on another machine opens as the bot's page and stays that machine's chat")
  func agentOnAnotherMachineKeepsItsMachine() async throws {
    let world = try await BotWorld(botProject: botProject)
    let remoteProject = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "remote")
    let agent = ChatSession(
      projectId: remoteProject.id, serverId: "remote", title: "Christmas list", createdBy: .agent,
      createdByAgent: AgentReference(agentId: world.botChat.id, machineId: "local"))
    let pages = try await world.pages(projects: [], sessions: [])
    await world.navigation.install(machineId: "remote", projects: [remoteProject], sessions: [agent])

    #expect(pages.show(agent) == world.bot)

    let shown = try #require(pages.agentPage(in: world.botWorkspace()))
    #expect(shown.id == agent.id)
    #expect(shown.serverId == "remote")
  }

  @Test("An open agent that was archived, or whose project is not loaded, gives the page back to the conversation")
  func unavailableAgentShowsTheConversation() async throws {
    let world = try await BotWorld(botProject: botProject)
    let agent = world.chat("Christmas list", in: appProject, createdBy: world.botChat)
    var archived = agent
    archived.isArchived = true
    let pages = try await world.pages(projects: [appProject], sessions: [agent])
    pages.show(agent)

    _ = try await world.pages(projects: [appProject], sessions: [archived])
    #expect(pages.page(of: world.bot) == .conversation)

    _ = try await world.pages(projects: [], sessions: [agent])
    #expect(pages.page(of: world.bot) == .conversation)
  }

  @Test("An archived agent is forgotten, so the page does not go back to it if it is restored")
  func archivedAgentIsForgotten() async throws {
    let world = try await BotWorld(botProject: botProject)
    let agent = world.chat("Christmas list", in: appProject, createdBy: world.botChat)
    var archived = agent
    archived.isArchived = true
    let pages = try await world.pages(projects: [appProject], sessions: [agent])
    pages.show(agent)

    pages.forgetArchivedAgent(of: world.bot)
    #expect(pages.page(of: world.bot).agent?.id == agent.id)

    _ = try await world.pages(projects: [appProject], sessions: [archived])
    pages.forgetArchivedAgent(of: world.bot)
    _ = try await world.pages(projects: [appProject], sessions: [agent])

    #expect(pages.page(of: world.bot) == .conversation)
  }

  @Test("An agent whose project has not loaded yet is kept, and takes the page once it loads")
  func agentWaitingForItsProjectIsKept() async throws {
    let world = try await BotWorld(botProject: botProject)
    let agent = world.chat("Christmas list", in: appProject, createdBy: world.botChat)
    let pages = try await world.pages(projects: [], sessions: [agent])
    pages.show(agent)

    pages.forgetArchivedAgent(of: world.bot)
    #expect(pages.page(of: world.bot) == .conversation)

    _ = try await world.pages(projects: [appProject], sessions: [agent])

    #expect(pages.page(of: world.bot).agent?.id == agent.id)
  }
}

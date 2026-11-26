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

  @Test("Opening the bot's own conversation from its agent's page closes that page")
  func conversationClosesTheAgentPage() async throws {
    let world = try await BotWorld(botProject: botProject)
    let agent = world.chat("Christmas list", in: appProject, createdBy: world.botChat)
    let pages = try await world.pages(projects: [appProject], sessions: [agent])
    pages.show(agent)

    #expect(pages.show(world.botChat) == world.bot)

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
}

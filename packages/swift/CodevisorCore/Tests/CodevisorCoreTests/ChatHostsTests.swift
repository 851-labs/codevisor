import CodevisorClient
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite("Chat hosts", .timeLimit(.minutes(1)))
struct ChatHostsTests {
  let botProject = Project.fromFolder(URL(fileURLWithPath: "/bots/helper"), serverId: "local")
  let appProject = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "local")
  let toolsProject = Project.fromFolder(URL(fileURLWithPath: "/src/tools"), serverId: "local")

  @Test("A bot's sub-agents, at any depth and in any project, open inside the bot")
  func botSubagentsOpenInTheBot() async throws {
    let world = try await BotWorld(botProject: botProject)
    let agent = world.chat("Christmas list", in: appProject, createdBy: world.botChat)
    let helper = world.chat("Price checker", in: appProject, createdBy: agent)
    let hosts = try await world.hosts(
      projects: [appProject], sessions: [agent, helper], workspaces: [world.workspace(agent, in: appProject)])

    #expect(hosts.host(of: agent) == .bot(world.bot))
    #expect(hosts.host(of: helper) == .bot(world.bot))
  }

  @Test("A chat left in a bot's layout is never a guest there")
  func botWorkspaceNeverHostsGuests() async throws {
    let world = try await BotWorld(botProject: botProject)
    let stray = world.chat("Stray", in: appProject)
    let hosts = try await world.hosts(
      projects: [appProject], sessions: [stray], workspaces: [world.botWorkspace(alsoShowing: stray)])

    #expect(hosts.host(of: stray) == .own)
  }

  @Test("An ordinary agent's sub-agent from another project is a guest in that agent's workspace")
  func ordinaryAgentHostsItsSubagents() async throws {
    let world = try await BotWorld(botProject: botProject)
    let lead = world.chat("Lead", in: toolsProject)
    let helper = world.chat("Helper", in: appProject, createdBy: lead)
    let leadWorkspace = world.workspace(lead, in: toolsProject)
    let hosts = try await world.hosts(
      projects: [appProject, toolsProject], sessions: [lead, helper], workspaces: [leadWorkspace])

    #expect(hosts.host(of: lead) == .own)
    guard case let .guest(host) = hosts.host(of: helper) else {
      Issue.record("Expected the helper to be a guest")
      return
    }
    #expect(host.id == leadWorkspace.id)
  }
}

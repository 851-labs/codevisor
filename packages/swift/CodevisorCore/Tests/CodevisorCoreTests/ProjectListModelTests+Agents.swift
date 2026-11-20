import Foundation
import Testing
@testable import CodevisorCore

@MainActor
extension ProjectListModelTests {
  @Test("A chat has agents only among the live chats it started")
  func agentsStartedByAChatSkipArchivedAndDetachedChats() {
    let model = ProjectListModel()
    let project = UUID()
    let bot = ChatSession(projectId: project)
    let started = AgentReference(agentId: bot.id, machineId: "local")
    let archived = ChatSession(projectId: project, createdByAgent: started, isArchived: true)
    let detached = ChatSession(projectId: project, createdByAgent: started, isDetached: true)
    let otherBots = ChatSession(projectId: project, createdByAgent: AgentReference(agentId: UUID(), machineId: "local"))
    let live = ChatSession(projectId: project, createdByAgent: started)
    model.sessions = [bot, archived, detached, otherBots]

    #expect(!model.hasAgents(startedBy: bot) { _ in true })

    model.sessions.append(live)

    #expect(model.hasAgents(startedBy: bot) { $0.id == live.id })
    #expect(!model.hasAgents(startedBy: bot) { $0.id != live.id })
  }
}

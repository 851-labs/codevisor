import Foundation
import Testing

@testable import CodevisorCore

@Suite("A thread in the transcript")
struct PresentedThreadTests {
  @Test("The bot whose screen shows the thread writes on the trailing side, and the other side on the leading")
  func viewerWritesOnTheTrailingSide() throws {
    let record = ServerBot.fixture(name: "Release")
    let release = try #require(Bot(serverId: "local", record: record))
    let releaseSide = ServerThreadParticipant(
      kind: .bot, name: "Release", agentId: record.sessionId, botId: record.id.uppercased())
    let agent = ServerThreadParticipant(kind: .agent, name: "Fix login", agentId: "agent-1", machineId: "machine-b")
    let messages = [
      ServerThreadMessage(
        id: "m1", threadId: "t1", sequence: 1, from: agent, text: "Login is **fixed**.",
        createdAt: "2026-11-12T10:00:00.000Z"),
      ServerThreadMessage(
        id: "m2", threadId: "t1", sequence: 2, from: releaseSide, text: "Thanks.",
        createdAt: "2026-11-12T10:00:05.000Z"),
    ]

    let conversation = TranscriptBotConversation.thread(messages, viewedBy: release)

    #expect(conversation.messages.map(\.id) == ["m1", "m2"])
    #expect(conversation.messages.map(\.side) == [.leading, .trailing])
    #expect(conversation.messages.map(\.sender) == [.bot, .bot])
    #expect(
      conversation.messages.map(\.author) == [
        TranscriptBotAuthor(id: "agent-1", name: "Fix login"),
        TranscriptBotAuthor(id: record.id.uppercased(), name: "Release"),
      ])
    #expect(conversation.messages.map(\.text) == ["Login is **fixed**.", "Thanks."])
    #expect(conversation.messages[1].sentAt == conversation.messages[0].sentAt?.addingTimeInterval(5))
    #expect(!conversation.isWorking)
  }
}

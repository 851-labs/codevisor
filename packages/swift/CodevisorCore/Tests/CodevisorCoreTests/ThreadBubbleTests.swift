import Foundation
import Testing

@testable import CodevisorCore

@Suite("Thread bubbles")
struct ThreadBubbleTests {
  let release = ServerThreadParticipant(kind: .bot, name: "Release", agentId: "chat-release", botId: "bot-release")
  let triage = ServerThreadParticipant(kind: .bot, name: "Triage", agentId: "chat-triage", botId: "bot-triage")

  @Test("A run of messages from one sender shows the name above its first and the avatar beside its last")
  func groupsRunsBySender() {
    let messages = [message(1, release), message(2, release), message(3, triage), message(4, release)]

    let rows = ThreadBubble.rows(for: messages)

    #expect(rows.map(\.showsName) == [true, false, true, true])
    #expect(rows.map(\.showsAvatar) == [false, true, true, true])
    #expect(rows.map(\.id) == ["m1", "m2", "m3", "m4"])
  }

  @Test("No messages make no rows")
  func emptyThread() {
    #expect(ThreadBubble.rows(for: []).isEmpty)
  }

  private func message(_ sequence: Int, _ from: ServerThreadParticipant) -> ServerThreadMessage {
    ServerThreadMessage(
      id: "m\(sequence)", threadId: "t1", sequence: sequence, from: from, text: "Text \(sequence)",
      createdAt: "2026-11-12T00:00:00.000Z")
  }
}

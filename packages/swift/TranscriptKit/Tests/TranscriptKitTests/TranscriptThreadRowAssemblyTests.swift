import ACPKit
import CodevisorProtocol
import Foundation
import Testing
@testable import TranscriptKit

@Suite("Thread rows")
struct TranscriptThreadRowAssemblyTests {
  private let start = Date(timeIntervalSince1970: 1_792_324_800)

  @Test("In a thread, each sender's run of bubbles is its own group, headed by the sender's name")
  func threadRunsAreNamed() throws {
    let release = TranscriptBotAuthor(id: "bot-release", name: "Release")
    let triage = TranscriptBotAuthor(id: "bot-triage", name: "Triage")
    let unnamed = TranscriptBotAuthor(id: "agent-far", name: "")
    let conversation = TranscriptBotConversation(
      messages: [
        TranscriptBotMessage(id: "a1", sender: .bot, text: "Is it green?", sentAt: start, author: release),
        TranscriptBotMessage(id: "a2", sender: .bot, text: "I want to ship.", sentAt: start, author: release),
        TranscriptBotMessage(
          id: "b1", sender: .bot, text: "Yes:\n\n```\nok\n```", sentAt: start.addingTimeInterval(1), author: triage),
        TranscriptBotMessage(
          id: "c1", sender: .bot, text: "Noted.", sentAt: start.addingTimeInterval(2), author: unnamed),
      ],
      isWorking: false)

    let rows = try TranscriptRowProjectionCache.project(
      TranscriptProjectionInput(thread: conversation),
      options: .init(includesConnectingRow: false, presentsBotConversation: true))

    #expect(
      rows.map(\.id) == [
        .botTimestamp("a1"), .botAuthorName("a1"), .botMessage("a1"), .botMessage("a2"),
        .botAuthorName("b1:0"), .botMessage("b1:0"), .botMessage("b1:1"), .botMessage("c1"),
      ])
    #expect(groupTails(rows) == ["a1": false, "a2": true, "b1:0": false, "b1:1": true, "c1": true])
    #expect(authorNames(rows) == ["Release", "Triage"])
  }

  private func authorNames(_ rows: [TranscriptPresentationRow]) -> [String] {
    rows.compactMap { row in
      if case let .botAuthorName(name) = row.content { return name }
      return nil
    }
  }

  private func groupTails(_ rows: [TranscriptPresentationRow]) -> [String: Bool] {
    rows.reduce(into: [:]) { tails, row in
      if case let .botMessage(message, _, isGroupTail) = row.content { tails[message.id] = isGroupTail }
    }
  }
}

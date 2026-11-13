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

  @Test("Thread messages with nothing between them in a bot's conversation share one line, per thread")
  func neighbouringThreadMessagesShareALine() throws {
    let asked = threadEvent("t1", "to", "Is it green?")
    let answered = threadEvent("t1", "from", "Yes.")
    let elsewhere = threadEvent("t2", "from", "Ping.")
    let later = threadEvent("t1", "from", "Still green.")
    var reply = AssistantTurn(entries: [.text(id: "work", markdown: "Telling the user")])
    reply.startedAt = start.addingTimeInterval(30)
    let conversation = TranscriptBotConversation(
      messages: [
        TranscriptBotMessage(id: "b1", sender: .bot, text: "It is green.", sentAt: start.addingTimeInterval(40))
      ],
      isWorking: false)
    let settled: [ConversationItem] = [
      .user(asked), .user(answered), .user(elsewhere), .assistant(AssistantMessage(turn: reply)), .user(later),
    ]

    let rows = try TranscriptRowProjectionCache.project(
      TranscriptProjectionInput(
        settledConversation: settled, pendingUserMessage: nil, activeItem: nil, setupPhases: [],
        waitingBackgroundTaskDescription: nil, waitingHarnessUpdateName: nil, isLoadingInitialHistory: false,
        serverWaitMessage: nil, sessionErrorMessage: nil, status: .idle, botConversation: conversation),
      options: .init(includesConnectingRow: false, presentsBotConversation: true))

    #expect(
      threadLines(rows) == [
        ThreadLine(id: .eventMarker(asked.id), threadID: "t1", bodies: ["Is it green?", "Yes."]),
        ThreadLine(id: .eventMarker(elsewhere.id), threadID: "t2", bodies: ["Ping."]),
        ThreadLine(id: .eventMarker(later.id), threadID: "t1", bodies: ["Still green."]),
      ])
    #expect(
      rows.map(\.id).filter { $0 != .botTimestamp("b1") }
        == [.eventMarker(asked.id), .eventMarker(elsewhere.id), .botMessage("b1"), .eventMarker(later.id)])
  }

  private struct ThreadLine: Equatable {
    let id: TranscriptPresentationRow.ID
    let threadID: String?
    let bodies: [String]
  }

  private func threadLines(_ rows: [TranscriptPresentationRow]) -> [ThreadLine] {
    rows.compactMap { row in
      guard case let .eventMarker(marker, _) = row.content else { return nil }
      return ThreadLine(id: row.id, threadID: marker.threadID, bodies: marker.events.map(\.body))
    }
  }

  private func threadEvent(_ threadID: String, _ direction: String, _ text: String) -> UserMessage {
    UserMessage(
      text: """
        <codevisor-event type="thread.message" threadId="\(threadID)" \(direction)="bot" botId="bot-triage" name="Triage">
        \(text)
        </codevisor-event>
        """, isEvent: true)
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

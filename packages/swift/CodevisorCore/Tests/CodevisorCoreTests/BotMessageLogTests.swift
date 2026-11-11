import Foundation
import Testing
import TranscriptKit

@testable import CodevisorCore

struct BotMessageLogTests {
  @Test("Messages stay in sequence order however pages and live messages arrive")
  func ordersBySequence() {
    var log = BotMessageLog()
    log.replace(with: [message("c", 30), message("a", 10)])
    log.upsert(message("d", 40))
    log.upsert(message("b", 20))
    log.prepend([message("z", 5), message("a", 10)])

    #expect(log.messages.map(\.id) == ["z", "a", "b", "c", "d"])
    #expect(log.sequences == [5, 10, 20, 30, 40])
  }

  @Test("An edited message replaces the old one, and an unchanged echo leaves the revision alone")
  func upsertReplacesAndIgnoresDuplicates() {
    var log = BotMessageLog()
    log.replace(with: [message("a", 1, text: "draft")])
    let afterReplace = log.revision

    log.upsert(message("a", 1, text: "draft"))
    #expect(log.revision == afterReplace)

    log.upsert(message("a", 1, text: "final"))
    #expect(log.revision != afterReplace)
    #expect(log.messages.map(\.text) == ["final"])
  }

  @Test("Delivered ids match case-insensitively and timestamps are parsed once on arrival")
  func normalizesIDsAndParsesDates() {
    var log = BotMessageLog()
    log.upsert(message("ABC-1", 1))

    #expect(log.contains(normalizedID: "abc-1"))
    #expect(log.messages.first?.sentAt == Date(timeIntervalSince1970: 1_792_314_001))
  }

  @Test("Unsent messages are placed after the delivered message they followed")
  func slotsUnsentMessagesAfterTheirAnchor() {
    var log = BotMessageLog()
    log.replace(with: [message("a", 1), message("b", 2), message("c", 3)])
    let unsent = [
      UnsentBotMessage(message: TranscriptBotMessage(id: "u2", sender: .user, text: "u2"), afterSequence: 2),
      UnsentBotMessage(message: TranscriptBotMessage(id: "u0", sender: .user, text: "u0"), afterSequence: 0),
      UnsentBotMessage(message: TranscriptBotMessage(id: "uEnd", sender: .user, text: "end"), afterSequence: nil),
    ]

    let ids = BotConversationTimeline.messages(delivered: log, unsent: unsent).map(\.id)
    #expect(ids == ["u0", "a", "b", "u2", "c", "uEnd"])
  }

  private func message(_ id: String, _ sequence: Int, text: String = "hi") -> ServerBotMessage {
    ServerBotMessage(
      id: id, sessionId: "s", sequence: sequence, sender: .bot, text: text, createdAt: "2026-10-18T09:00:01.000Z")
  }
}

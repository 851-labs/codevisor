import Foundation
import Testing

@testable import CodevisorClient
@testable import CodevisorCore

@MainActor
struct SessionModelEventPromptTests {
  private let sessionID = UUID()
  private let eventText = "<codevisor-event type=\"session.errored\" title=\"Deploy\">\nboom\n</codevisor-event>"

  @Test("Transcript items with the event origin map to event user messages")
  func transcriptOriginMarksEvents() throws {
    let transport = ServerSessionTransport(client: FakeSessionServerClient(sessionId: sessionID), sessionId: sessionID)
    let page = try JSONDecoder().decode(
      ServerTranscriptPage.self,
      from: Data(
        """
        {
          "items": [\(transcriptItem(sequence: 0, origin: nil)), \(transcriptItem(sequence: 1, origin: "event"))],
          "setupActivities": [], "stateUpdates": [], "hasNewer": false, "hasMore": false, "eventCursor": 1
        }
        """.utf8))

    let users = transport.historyPage(from: page).conversation.compactMap { item -> UserMessage? in
      if case let .user(message) = item { message } else { nil }
    }

    #expect(users.map(\.isEvent) == [false, true])
  }

  @Test("A promoted system queue item lands as an event without a send animation")
  func promotedSystemPromptIsAnEvent() {
    let model = makeModel()
    defer { model.shutdown() }
    var promoted: [UUID?] = []
    model.onQueuedPromptPromoted = { promoted.append($0) }
    let itemID = UUID()

    model.applyQueuedPromptSnapshot([queueItem(id: itemID)])
    model.applyQueuedPromptSnapshot([])
    model.apply(.userMessage(id: itemID.uuidString, text: eventText, attachments: [], isEvent: true))

    #expect(promoted.isEmpty)
    #expect(users(model).map(\.isEvent) == [true])
    #expect(users(model).map(\.id) == [itemID])
  }

  @Test("A repeated echo of an event prompt keeps it an event")
  func echoKeepsEventFlag() {
    let model = makeModel()
    defer { model.shutdown() }
    let messageID = UUID().uuidString

    model.apply(.userMessage(id: messageID, text: eventText, attachments: [], isEvent: true))
    model.apply(.userMessage(id: messageID, text: eventText, attachments: []))

    #expect(users(model).map(\.isEvent) == [true])
  }

  private func makeModel() -> SessionModel {
    SessionModel(
      serverTransport: ServerSessionTransport(
        client: FakeSessionServerClient(sessionId: sessionID), sessionId: sessionID),
      sessionId: sessionID.uuidString
    )
  }

  private func users(_ model: SessionModel) -> [UserMessage] {
    model.conversation.compactMap { item in
      if case let .user(message) = item { message } else { nil }
    }
  }

  private func queueItem(id: UUID) -> ServerPromptQueueItem {
    ServerPromptQueueItem(
      id: id.uuidString, sessionId: sessionID.uuidString, text: eventText,
      createdAt: "2026-10-19T00:00:00.000Z", updatedAt: "2026-10-19T00:00:00.000Z", origin: "system"
    )
  }

  private func transcriptItem(sequence: Int, origin: String?) -> String {
    let originField = origin.map { #""origin": "\#($0)","# } ?? ""
    return """
      {
        "id": "\(UUID())", "sessionId": "\(sessionID)", "sequence": \(sequence), "role": "user",
        "text": "prompt \(sequence)", \(originField) "isGenerating": false, "hasDetails": false,
        "createdAt": "2026-10-19T00:00:00.000Z", "updatedAt": "2026-10-19T00:00:00.000Z", "revision": 1
      }
      """
  }
}

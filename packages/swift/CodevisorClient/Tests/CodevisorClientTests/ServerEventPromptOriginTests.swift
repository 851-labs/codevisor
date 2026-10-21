import ACPKit
import Foundation
import Testing

@testable import CodevisorClient

struct ServerEventPromptOriginTests {
  private let eventText =
    #"<codevisor-event type="session.turn_ended" sessionId="s1" title="Fix login">"#
    + "\nDone\n</codevisor-event>"

  @Test("Transcript items marked with the event origin decode as events")
  func transcriptItemOrigin() throws {
    let event = try decodeTranscriptItem(origin: #""origin": "event","#)
    let typed = try decodeTranscriptItem(origin: "")

    #expect(event.isEvent)
    #expect(!typed.isEvent)
  }

  @Test("Live user output carries the event origin into the stream event")
  func liveOutputOrigin() {
    let event = outputEvents(origin: .string("event"))
    let typed = outputEvents(origin: nil)

    #expect(event == [.userMessage(id: "m1", text: eventText, attachments: [], isEvent: true)])
    #expect(typed == [.userMessage(id: "m1", text: eventText, attachments: [], isEvent: false)])
  }

  @Test("Steered user output names the assistant item that continues the turn")
  func steeredOutputAssistantItem() {
    let itemId = UUID()
    let events = ServerSessionEventDecoder.decode(
      from: envelope(
        kind: "session.output",
        payload: .object([
          "role": .string("user"), "messageId": .string("m2"), "text": .string("actually bham al"),
          "assistantItemId": .string(itemId.uuidString.lowercased()),
        ])
      ))

    #expect(
      events == [
        .userMessage(id: "m2", text: "actually bham al", attachments: [], assistantItemId: itemId)
      ])
  }

  @Test("Queued prompts keep the system origin so they can be hidden")
  func queueItemOrigin() {
    let events = ServerSessionEventDecoder.decode(
      from: envelope(
        kind: "session.queue.updated",
        payload: .object(["queue": .array([queueItem(id: "q1", origin: "system"), queueItem(id: "q2", origin: nil)])])
      ))

    guard case let .queueUpdated(queue) = events.first else {
      Issue.record("Missing queue update")
      return
    }
    #expect(queue.map(\.isSystem) == [true, false])
  }

  private func decodeTranscriptItem(origin: String) throws -> ServerTranscriptItem {
    let json = """
      {
        "id": "item-1", "messageId": "m1", "sessionId": "s1", "sequence": 0, "role": "user",
        "text": "event", \(origin) "isGenerating": false, "hasDetails": false,
        "createdAt": "2026-10-19T00:00:00.000Z", "updatedAt": "2026-10-19T00:00:00.000Z",
        "revision": 1
      }
      """
    return try JSONDecoder().decode(ServerTranscriptItem.self, from: Data(json.utf8))
  }

  private func outputEvents(origin: JSONValue?) -> [ServerSessionStreamEvent] {
    var payload: [String: JSONValue] = [
      "role": .string("user"), "messageId": .string("m1"), "text": .string(eventText), "startsTurn": .bool(true),
    ]
    payload["origin"] = origin
    return ServerSessionEventDecoder.decode(from: envelope(kind: "session.output", payload: .object(payload)))
  }

  private func queueItem(id: String, origin: String?) -> JSONValue {
    var item: [String: JSONValue] = [
      "id": .string(id), "sessionId": .string("s1"), "text": .string(eventText),
      "createdAt": .string("2026-10-19T00:00:00.000Z"), "updatedAt": .string("2026-10-19T00:00:00.000Z"),
    ]
    item["origin"] = origin.map(JSONValue.string)
    return .object(item)
  }

  private func envelope(kind: String, payload: JSONValue) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: 1, serverId: "local", kind: kind, subjectId: "s1", createdAt: "2026-10-19T00:00:00.000Z", payload: payload)
  }
}

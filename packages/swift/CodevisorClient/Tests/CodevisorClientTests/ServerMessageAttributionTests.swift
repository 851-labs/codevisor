import ACPKit
import Foundation
import Testing
import TranscriptKit

@testable import CodevisorClient

@Suite("App message attribution")
struct ServerMessageAttributionTests {
  private let attribution = UserMessageAttribution.app(viewId: "view-1", plugin: "Zillow")

  @Test("An app's message is a plain prompt that names the app it came from")
  func promptBody() async throws {
    let transport = AttributionTransport()
    let client = CodevisorServerClient(config: .init(requestTransport: transport))
    let sessionId = UUID()

    _ = try await client.promptSession(id: sessionId, text: "Tour 12 Main St", attribution: attribution)

    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/v1/sessions/\(sessionId.uuidString)/prompt")
    let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(request.httpBody))
    #expect(body["text"] == .string("Tour 12 Main St"))
    #expect(
      body["attribution"]
        == .object(["kind": .string("app"), "viewId": .string("view-1"), "plugin": .string("Zillow")]))
    #expect(body["delivery"] == nil)
    #expect(body["messageId"] == nil)
  }

  @Test("Live and stored user messages keep the app attribution, and others have none")
  func decoding() throws {
    let attributed: JSONValue = .object([
      "kind": .string("app"), "viewId": .string("view-1"), "plugin": .string("Zillow"),
    ])
    let live = ServerSessionEventDecoder.decode(from: output(attribution: attributed))
    let plain = ServerSessionEventDecoder.decode(from: output(attribution: nil))
    let stored = try storedItem(
      attribution: #""attribution": {"kind": "app", "viewId": "view-1", "plugin": "Zillow"},"#)

    #expect(live == [.userMessage(id: "m1", text: "Tour it", attachments: [], attribution: attribution)])
    #expect(plain == [.userMessage(id: "m1", text: "Tour it", attachments: [])])
    #expect(stored.attribution == attribution)
    #expect(try storedItem(attribution: "").attribution == nil)
  }

  @Test("Queued app messages keep their attribution")
  func queuedItem() throws {
    let json = #"""
      {"id": "q1", "sessionId": "s1", "text": "Tour it", "createdAt": "2026-10-27T00:00:00.000Z",
       "updatedAt": "2026-10-27T00:00:00.000Z", "attribution": {"kind": "app", "viewId": "view-1", "plugin": "Zillow"}}
      """#

    let item = try JSONDecoder().decode(ServerPromptQueueItem.self, from: Data(json.utf8))

    #expect(item.attribution == attribution)
  }

  private func output(attribution: JSONValue?) -> ServerEventEnvelope {
    var payload: [String: JSONValue] = [
      "role": .string("user"), "messageId": .string("m1"), "text": .string("Tour it"),
    ]
    payload["attribution"] = attribution
    return ServerEventEnvelope(
      id: 1, serverId: "local", kind: "session.output", subjectId: "s1", createdAt: "2026-10-27T00:00:00.000Z",
      payload: .object(payload))
  }

  private func storedItem(attribution: String) throws -> ServerTranscriptItem {
    let json = """
      {
        "id": "item-1", "messageId": "m1", "sessionId": "s1", "sequence": 0, "role": "user",
        "text": "Tour it", \(attribution) "isGenerating": false, "hasDetails": false,
        "createdAt": "2026-10-27T00:00:00.000Z", "updatedAt": "2026-10-27T00:00:00.000Z", "revision": 1
      }
      """
    return try JSONDecoder().decode(ServerTranscriptItem.self, from: Data(json.utf8))
  }
}

private actor AttributionTransport: ServerRequestTransport {
  var requests: [URLRequest] = []

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let body = #"{"accepted":true,"sessionId":"s1"}"#
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    )
  }
}

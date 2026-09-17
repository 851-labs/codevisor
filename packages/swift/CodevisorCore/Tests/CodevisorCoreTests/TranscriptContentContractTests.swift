import ACPKit
import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCore
@testable import CodevisorClient

@MainActor
struct TranscriptContentContractTests {
  @Test func workedDetailsInstallOnceAfterEveryStoragePageArrives() async {
    let sessionID = UUID()
    let itemID = UUID().uuidString
    let client = FakeSessionServerClient(sessionId: sessionID)
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [
        transcriptStateItem(id: UUID(uuidString: itemID)!, sessionId: sessionID, text: "Answer", hasDetails: true)
      ],
      hasMore: false, eventCursor: 200)
    let waiting = TestSignal()
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    client.transcriptDetailHandler = { _, after in
      let start = after.flatMap(Int.init) ?? 0
      if start == 32 {
        waiting.signal()
        for await _ in gate { break }
      }
      let end = min(start + 32, 130)
      return ServerTranscriptItemDetails(
        itemId: itemID, revision: 200, eventCursor: 200,
        entries: (start..<end).map { index in
          ServerTranscriptEntry(
            key: "tool:\(index)", position: index, revision: index + 1,
            payload: .object([
              "sessionUpdate": .string("tool_call"), "toolCallId": .string("tool-\(index)"),
              "title": .string("Read \(index)"), "status": .string("completed"),
              "isSnapshot": .bool(true), "statePosition": .number(Double(index)),
              "stateRevision": .number(Double(index + 1)),
            ]))
        }, nextAfter: end < 130 ? String(end) : nil)
    }
    let model = SessionModel(
      serverTransport: .init(client: client, sessionId: sessionID), sessionId: sessionID.uuidString)
    defer { model.shutdown(); release.finish() }
    await model.loadHistory()
    let before = model.conversation
    let loading = Task { await model.loadTranscriptDetails(itemId: itemID) }
    await waiting.wait()
    #expect(model.conversation == before)
    release.finish()
    #expect(await loading.value)
    guard case let .assistant(message) = model.conversation.first else { Issue.record("Missing turn"); return }
    #expect(message.id.uuidString == itemID)
    #expect(message.turn.toolCalls.map(\.toolCallId) == (0..<130).map { "tool-\($0)" })
    #expect(!message.turn.hasDeferredWorkedDetails)
    #expect(message.turn.hasHydratedWorkedDetails)
    #expect(client.transcriptDetailCursors == [nil, "32", "64", "96", "128"])
    #expect(await model.loadTranscriptDetails(itemId: itemID))
    #expect(client.transcriptDetailRequestCount == 5)
  }

  @Test func openingOtherTurnsNeverEvictsAlreadyLoadedWork() async {
    let sessionID = UUID()
    let ids = (0..<12).map { _ in UUID().uuidString }
    let client = FakeSessionServerClient(sessionId: sessionID)
    client.initialTranscriptPage = ServerTranscriptPage(
      items: ids.map {
        transcriptStateItem(id: UUID(uuidString: $0)!, sessionId: sessionID, text: "Answer", hasDetails: true)
      },
      hasMore: false, eventCursor: 1)
    client.transcriptDetailHandler = { itemID, _ in
      ServerTranscriptItemDetails(
        itemId: itemID, revision: 1, eventCursor: 1,
        entries: [
          ServerTranscriptEntry(
            key: "tool:read", position: 0, revision: 1,
            payload: .object([
              "sessionUpdate": .string("tool_call"), "toolCallId": .string("read-\(itemID)"),
              "title": .string("Read source"), "status": .string("completed"),
            ]))
        ])
    }
    let model = SessionModel(
      serverTransport: .init(client: client, sessionId: sessionID), sessionId: sessionID.uuidString)
    defer { model.shutdown() }
    await model.loadHistory()
    for id in ids { #expect(await model.loadTranscriptDetails(itemId: id)) }
    for item in model.conversation {
      guard case let .assistant(message) = item else { continue }
      #expect(message.turn.toolCalls.count == 1)
      #expect(message.turn.hasHydratedWorkedDetails)
      #expect(!message.turn.hasDeferredWorkedDetails)
    }
    #expect(await model.loadTranscriptDetails(itemId: ids[0]))
    #expect(client.transcriptDetailRequestCount == ids.count)
  }

  @Test func longTextLoadsCompletelyBeforeItsHistoryPageIsPublished() async throws {
    let sessionID = UUID()
    let client = FakeSessionServerClient(sessionId: sessionID)
    let blocks = ["```swift\n" + String(repeating: "😀a", count: 9_000), "let value = ", "123\n```\nAfter"]
    let text = blocks.joined()
    let resource = try resource(name: "text", encoding: "text", count: blocks.count, size: text.utf16.count * 2)
    client.transcriptBodyHandler = { _, _, _, position in
      try Self.block(position: position, text: blocks[position], revision: 1)
    }
    let transport = ServerSessionTransport(client: client, sessionId: sessionID)
    let original = UserMessage(text: "Preview", textResource: resource)
    let page = TranscriptHistoryPage(conversation: [.user(original)], hasMore: false, eventCursor: 4)
    let loaded = try await transport.completeHistoryPage(page)
    guard case let .user(message) = loaded.conversation.first else { Issue.record("Missing message"); return }
    #expect(message.id == original.id)
    #expect(message.text == text)
    #expect(message.textResource == nil)
    #expect(client.transcriptBodyRequests.sorted() == [0, 1, 2])
  }

  @Test func replacedBodyCannotMixGenerations() async throws {
    let sessionID = UUID()
    let client = FakeSessionServerClient(sessionId: sessionID)
    let resource = try resource(name: "text", encoding: "text", count: 2, size: 8)
    client.transcriptBodyHandler = { _, _, _, position in
      try Self.block(position: position, text: "aa", revision: position == 0 ? 1 : 2)
    }
    let content = ServerTranscriptContent(transport: .init(client: client, sessionId: sessionID))
    await #expect(throws: (any Error).self) {
      try await content.field(resource.fields[0], resource: resource)
    }
  }

  @Test func shortenedBodyReloadsCurrentHistoryInsteadOfPublishingAPartialMessage() async throws {
    let sessionID = UUID()
    let itemID = UUID()
    let client = FakeSessionServerClient(sessionId: sessionID)
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [transcriptStateItem(id: itemID, sessionId: sessionID, text: "Final answer")],
      hasMore: false, eventCursor: 2)
    let resource = try resource(name: "text", encoding: "text", count: 2, size: 8)
    client.transcriptBodyHandler = { _, _, _, position in
      if position == 1 { throw CodevisorServerClientError.httpStatus(404, "Body replaced") }
      return try Self.block(position: 0, text: "aa", revision: 1)
    }
    let page = TranscriptHistoryPage(
      conversation: [.user(UserMessage(text: "Preview", textResource: resource))], hasMore: false, eventCursor: 1)
    let loaded = try await ServerSessionTransport(client: client, sessionId: sessionID).completeHistoryPage(page)
    #expect(loaded.eventCursor == 2)
    guard case let .assistant(message) = loaded.conversation.first else { Issue.record("Missing answer"); return }
    #expect(message.id == itemID)
    guard case let .text(_, text) = message.turn.finalText else { Issue.record("Missing text"); return }
    #expect(text == "Final answer")
  }

  @Test func streamedToolFieldsUseTheOriginalStructuredOutput() async throws {
    let sessionID = UUID()
    let client = FakeSessionServerClient(sessionId: sessionID)
    let output: JSONValue = .object(["text": .string(String(repeating: "output\n", count: 5_000))])
    let encoded = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
    let resource = try resource(name: "rawOutput", encoding: "json", count: 1, size: encoded.utf8.count)
    client.transcriptBodyHandler = { _, _, _, position in
      try Self.block(position: position, text: encoded, revision: 1)
    }
    let transport = ServerSessionTransport(client: client, sessionId: sessionID)
    let stream = transport.streamEnvelopes(since: 0)
    var iterator = stream.makeAsyncIterator()
    let resourceJSON = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(resource))
    for revision in 1...2 {
      client.emit(
        ServerEventEnvelope(
          id: revision, serverId: "local", kind: "session.output", subjectId: sessionID.uuidString,
          createdAt: "2026-09-17T00:00:00.000Z",
          payload: .object([
            "sessionUpdate": .string("tool_call"), "toolCallId": .string("read"), "title": .string("Read"),
            "status": .string(revision == 1 ? "in_progress" : "completed"), "detailResource": resourceJSON,
          ])))
      guard case let .update(.toolCall(call)) = try await iterator.next()?.event else {
        Issue.record("Missing tool"); return
      }
      #expect(call.rawOutput == output)
      #expect(call.detailResource == nil)
    }
    #expect(client.transcriptBodyRequests == [0])
    client.finishEvents()
  }

  private func resource(name: String, encoding: String, count: Int, size: Int) throws -> ToolDetailResource {
    try JSONDecoder().decode(
      ToolDetailResource.self,
      from: JSONSerialization.data(withJSONObject: [
        "itemId": "item", "entryKey": "entry",
        "fields": [
          [
            "name": name, "encoding": encoding, "revision": 1, "generation": 1,
            "sizeBytes": size, "pageCount": count,
          ]
        ],
      ]))
  }

  private nonisolated static func block(position: Int, text: String, revision: Int) throws -> ServerTranscriptBodyPage {
    try JSONDecoder().decode(
      ServerTranscriptBodyPage.self,
      from: JSONSerialization.data(withJSONObject: [
        "position": position, "text": text, "revision": revision, "encoding": "text",
      ]))
  }
}

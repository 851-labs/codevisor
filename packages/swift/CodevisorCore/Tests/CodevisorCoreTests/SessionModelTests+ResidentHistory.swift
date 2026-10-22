import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("Loading older history retains the visible document and live work")
  func loadedHistoryAndWorkStayResident() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString)
    defer { model.shutdown() }
    func page(_ range: Range<Int>) -> ServerTranscriptPage {
      ServerTranscriptPage(
        items: range.map { sequence in
          ServerTranscriptItem(
            id: UUID().uuidString, sessionId: sessionId.uuidString, sequence: sequence,
            role: .user, text: "Message \(sequence)", createdAt: "2026-06-30T00:00:00.000Z",
            updatedAt: "2026-06-30T00:00:00.000Z", isGenerating: false,
            hasDetails: false, revision: 1)
        }, nextBefore: String(range.lowerBound), hasMore: range.lowerBound > 0,
        eventCursor: 1)
    }
    client.initialTranscriptPage = page(64..<96)
    await model.loadHistoryForInitialDisplay()
    let latest = model.conversation
    client.olderTranscriptPage = page(0..<64)
    #expect(await model.loadOlderHistory() == 64)
    #expect(model.settledConversation.count == 96)
    #expect(Array(model.conversation.suffix(32)) == latest)
    #expect(!model.hasOlderHistory)
    let historyIDs = model.conversation.map(\.id)
    for index in 0..<160 {
      model.apply(.update(.toolCall(ToolCall(toolCallId: "tool-\(index)", title: "Tool \(index)", status: .completed))))
    }
    guard case let .assistant(message) = model.activeItem else { Issue.record("Missing live turn"); return }
    #expect(message.turn.toolCalls.count == 160)
    #expect(!message.turn.hasDeferredWorkedDetails)
    #expect(Array(model.conversation.prefix(96)).map(\.id) == historyIDs)
  }

  @Test("Older history fetched before the transcript was replaced cannot leave a gap")
  func olderHistoryFromReplacedTranscriptIsDiscarded() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString)
    defer { model.shutdown() }
    let ids = (0..<38).map { _ in UUID() }
    func page(_ range: Range<Int>, eventCursor: Int = 1) -> ServerTranscriptPage {
      ServerTranscriptPage(
        items: range.map { sequence in
          ServerTranscriptItem(
            id: ids[sequence].uuidString, sessionId: sessionId.uuidString, sequence: sequence,
            role: .user, text: "Message \(sequence)", createdAt: "2026-06-30T00:00:00.000Z",
            updatedAt: "2026-06-30T00:00:00.000Z", isGenerating: false,
            hasDetails: false, revision: 1)
        }, nextBefore: String(range.lowerBound), hasMore: range.lowerBound > 0,
        eventCursor: eventCursor)
    }
    client.initialTranscriptPage = page(10..<18)
    await model.loadHistoryForInitialDisplay()
    let olderPages = ["10": page(2..<10), "30": page(22..<30)]
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    client.olderTranscriptPageHandler = { before in
      if before == "10" { for await _ in gate { break } }
      return olderPages[before]!
    }

    let loading = Task { await model.loadOlderHistory() }
    await client.olderTranscriptPageRequests.wait()
    client.initialTranscriptPage = page(30..<38, eventCursor: 2)
    guard case .loaded = await model.loadHistoryForConnectionRecovery() else {
      loading.cancel()
      release.finish()
      Issue.record("Expected the replacement page to load")
      _ = await loading.value
      return
    }
    #expect(model.conversation.map(\.id) == Array(ids[30..<38]))
    release.yield()
    release.finish()

    #expect(await loading.value == 8)
    #expect(model.conversation.map(\.id) == Array(ids[22..<38]))
    #expect(client.transcriptPageRequests.map(\.before) == [nil, "10", nil, "30"])
  }
}

extension SessionModelTests {
  @Test("A failed initial load surfaces the server's message")
  func failedInitialLoadSurfacesError() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.failNextTranscriptPages(
      1, with: CodevisorServerClientError.httpStatus(500, #"{"error":"Transcript store unavailable"}"#))
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString)
    defer { model.shutdown() }

    await model.loadHistoryForInitialDisplay()

    #expect(model.errorMessage == "Transcript store unavailable")
    #expect(model.conversation.isEmpty)
  }

  @Test("A failed older page keeps its cursor so scrolling up can retry it")
  func failedOlderPageCanBeRetried() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let item = ServerTranscriptItem(
      id: UUID().uuidString, sessionId: sessionId.uuidString, sequence: 1,
      role: .user, text: "Newest", createdAt: "2026-06-30T00:00:00.000Z",
      updatedAt: "2026-06-30T00:00:00.000Z", isGenerating: false,
      hasDetails: false, revision: 1)
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [item], nextBefore: "1", hasMore: true, eventCursor: 1)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString)
    defer { model.shutdown() }
    await model.loadHistoryForInitialDisplay()
    client.failNextTranscriptPages(
      1, with: CodevisorServerClientError.httpStatus(503, #"{"error":"Try again shortly"}"#))

    #expect(await model.loadOlderHistory() == 0)

    #expect(model.errorMessage == "Try again shortly")
    #expect(model.hasOlderHistory)
    #expect(!model.isLoadingOlderHistory)
    #expect(await model.loadOlderHistory() == 0)
    #expect(client.transcriptPageRequests.map(\.before) == [nil, "1", "1"])
  }
}

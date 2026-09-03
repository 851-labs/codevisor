import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

/// A machine's route flipping (direct ↔ relay) mid-turn used to tear the
/// model down and reload history, which rewound the streaming transcript to
/// a server snapshot and re-typed it. These cover the two guarantees that
/// replaced that: a transport swap resumes from the applied cursor, and a
/// history snapshot older than the applied stream is never installed.
extension SessionModelTests {
  private func chunkEnvelope(
    id: Int,
    sessionId: UUID,
    messageId: String = "msg-answer",
    text: String
  ) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: id,
      serverId: "local",
      kind: "session.output",
      subjectId: sessionId.uuidString,
      createdAt: "2026-09-02T21:39:\(String(format: "%02d", id)).000Z",
      payload: .object([
        "sessionUpdate": .string("agent_message_chunk"),
        "messageId": .string(messageId),
        "content": .object(["type": .string("text"), "text": .string(text)]),
      ])
    )
  }

  private func finalMarkdown(_ model: SessionModel) -> String? {
    guard case let .assistant(assistant) = model.conversation.last,
      case let .text(_, markdown) = assistant.turn.finalText
    else { return nil }
    return markdown
  }

  @Test("Applying stream events advances the resume cursor")
  func appliedEventsAdvanceResumeCursor() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [], nextBefore: nil, hasMore: false, eventCursor: 0
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await model.loadHistory()
    await model.send("describe the repo")
    #expect(model.serverEventCursor == 0)

    client.emit(chunkEnvelope(id: 10, sessionId: sessionId, text: "This repo is Codevisor.\n\n"))
    client.emit(chunkEnvelope(id: 11, sessionId: sessionId, text: "- Run multiple sessions\n"))
    await settleUntil { self.finalMarkdown(model)?.contains("Run multiple") == true }

    #expect(model.serverEventCursor == 11)
    model.shutdown()
  }

  @Test("A route flip re-homes a streaming turn without rewinding it")
  func adoptTransportResumesFromAppliedCursor() async {
    let sessionId = UUID()
    let direct = FakeSessionServerClient(sessionId: sessionId)
    direct.echoOnPrompt = false
    direct.initialTranscriptPage = ServerTranscriptPage(
      items: [], nextBefore: nil, hasMore: false, eventCursor: 0
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: direct, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await model.loadHistory()
    await model.send("describe the repo")
    direct.emit(chunkEnvelope(id: 10, sessionId: sessionId, text: "Its main capabilities are:\n"))
    direct.emit(chunkEnvelope(id: 11, sessionId: sessionId, text: "- Run multiple sessions\n"))
    direct.emit(chunkEnvelope(id: 12, sessionId: sessionId, text: "- Provide a terminal\n"))
    await settleUntil { self.finalMarkdown(model)?.contains("Provide a terminal") == true }
    let streamedSoFar = finalMarkdown(model)
    #expect(model.serverEventCursor == 12)

    // The relay client is a different server connection to the same
    // session. Like the real server, it replays only events newer than the
    // cursor it is asked for.
    let relay = FakeSessionServerClient(sessionId: sessionId)
    await model.adoptTransport(ServerSessionTransport(client: relay, sessionId: sessionId))
    await settleUntil { !relay.sessionEventSinceValues.isEmpty }

    #expect(relay.sessionEventSinceValues == [12])
    #expect(direct.transcriptPageRequests.count == 1)
    #expect(relay.transcriptPageRequests.isEmpty)
    // Nothing on screen moved: same text, still generating.
    #expect(finalMarkdown(model) == streamedSoFar)
    #expect(model.isSending)

    relay.emit(chunkEnvelope(id: 13, sessionId: sessionId, text: "- Connect to remote machines\n"))
    await settleUntil { self.finalMarkdown(model)?.contains("Connect to remote") == true }

    #expect(
      finalMarkdown(model)
        == "Its main capabilities are:\n- Run multiple sessions\n- Provide a terminal\n- Connect to remote machines\n"
    )
    #expect(model.serverEventCursor == 13)
    model.shutdown()
  }

  @Test("A history snapshot older than the applied stream is never installed")
  func reconcileKeepsNewerAppliedState() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [], nextBefore: nil, hasMore: false, eventCursor: 0
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await model.loadHistory()
    await model.send("describe the repo")
    client.emit(chunkEnvelope(id: 10, sessionId: sessionId, text: "Its main capabilities are:\n"))
    client.emit(chunkEnvelope(id: 11, sessionId: sessionId, text: "- Run multiple sessions\n"))
    client.emit(chunkEnvelope(id: 12, sessionId: sessionId, text: "- Provide a terminal\n"))
    await settleUntil { self.finalMarkdown(model)?.contains("Provide a terminal") == true }
    let streamedSoFar = finalMarkdown(model)
    let subscriptionsBefore = client.sessionEventSinceValues.count

    // The server's durable page lags the socket: it still ends after the
    // first list marker, at an older cursor.
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: true,
      stopReason: nil,
      eventCursor: 10,
      text: "Its main capabilities are:\n- "
    )

    await model.reconcileIfInFlight()

    #expect(finalMarkdown(model) == streamedSoFar)
    #expect(model.isSending)
    #expect(client.transcriptDetailRequestCount == 0)
    await settleUntil { client.sessionEventSinceValues.count > subscriptionsBefore }
    #expect(client.sessionEventSinceValues.last == 12)

    // A snapshot that is genuinely newer still wins.
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: false,
      stopReason: "end_turn",
      eventCursor: 20,
      text: "Its main capabilities are:\n- Run multiple sessions\n- Provide a terminal\n- Done."
    )
    await model.reconcileIfInFlight()

    #expect(finalMarkdown(model)?.hasSuffix("- Done.") == true)
    #expect(model.isSending == false)
    model.shutdown()
  }
}

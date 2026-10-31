import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("SessionModel")
struct SessionModelTests {
  init() {
    SessionModel.eventFlushInterval = .zero
    SessionModel.cancellationTerminalEventWaitDelay = .zero
  }

  @Test("The optimistic message is visible before prompt transport completes")
  func optimisticMessagePrecedesTransportCompletion() async {
    let sessionId = UUID()
    let messageId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let (gate, releasePrompt) = AsyncStream.makeStream(of: Void.self)
    client.holdPrompts(until: gate)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    var locallyAppendedID: UUID?
    model.onLocalUserMessageAppended = { locallyAppendedID = $0 }

    let send = Task {
      await model.send(UserMessage(id: messageId, text: "  show this now  "))
    }
    await settleUntil {
      client.promptedMessageIds.count == 1
    }

    #expect(userMessages(model).map(\.id) == [messageId])
    #expect(userMessages(model).map(\.text) == ["show this now"])
    #expect(client.promptedTexts == ["show this now"])
    #expect(locallyAppendedID == messageId)
    #expect(client.promptedMessageIds == [messageId.uuidString.lowercased()])

    releasePrompt.yield()
    releasePrompt.finish()
    await send.value
  }

  @Test("The prompt carries the optimistic message id; the echo reconciles by identity")
  func echoReconcilesByIdentity() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await model.send("run pwd")
    let optimisticId = userMessages(model).first!.id
    #expect(client.promptedMessageIds == [optimisticId.uuidString.lowercased()])
    client.emit(
      ServerEventEnvelope(
        id: 1,
        serverId: "local",
        kind: "session.output",
        subjectId: sessionId.uuidString,
        createdAt: "2026-07-18T00:00:00.000Z",
        payload: .object([
          "role": .string("user"),
          "messageId": .string(optimisticId.uuidString.lowercased()),
          "text": .string("run  pwd"),
        ])
      ))
    client.emit(
      ServerEventEnvelope(
        id: 2,
        serverId: "local",
        kind: "session.updated",
        subjectId: sessionId.uuidString,
        createdAt: "2026-07-18T00:00:01.000Z",
        payload: .object(["stopReason": .string("end_turn")])
      ))
    await settleUntil { !model.isSending }
    #expect(userMessages(model).count == 1)
    #expect(userMessages(model).first?.text == "run pwd")
  }

  @Test("Retry starts a new assistant attempt without duplicating the user message")
  func retryResponseDoesNotDuplicateUserMessage() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    let attachment = Attachment(
      fileId: "retry-file-1", name: "note.txt", mimeType: "text/plain", sizeBytes: 17, kind: .file
    )
    await model.send("finish the change", attachments: [attachment])
    await settleUntil { !model.isSending }
    let original = try! #require(userMessages(model).first)
    await model.retryResponse(to: original)
    await settleUntil { !model.isSending }

    #expect(
      client.promptedTexts == [
        "finish the change",
        "finish the change",
      ])
    #expect(
      client.promptedMessageIds == [
        original.id.uuidString.lowercased(),
        original.id.uuidString.lowercased(),
      ])
    #expect(
      client.promptedAttachments == [
        [
          ServerAttachmentRef(
            fileId: "retry-file-1", name: "note.txt", mimeType: "text/plain", sizeBytes: 17, kind: .file
          )
        ],
        [
          ServerAttachmentRef(
            fileId: "retry-file-1", name: "note.txt", mimeType: "text/plain", sizeBytes: 17, kind: .file
          )
        ],
      ])
    #expect(userMessages(model).map(\.text) == ["finish the change"])
    #expect(
      model.conversation.filter {
        if case .assistant = $0 { return true }
        return false
      }.count == 2)
  }

  @Test("A user echo after an agent restart never duplicates the message")
  func echoAfterAgentRestartDedupes() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await model.send("run pwd")
    client.emit(
      ServerEventEnvelope(
        id: 1,
        serverId: "local",
        kind: "session.error",
        subjectId: sessionId.uuidString,
        createdAt: "2026-07-18T00:00:00.000Z",
        payload: .object(["message": .string("codex app-server exited")])
      ))
    client.emit(
      ServerEventEnvelope(
        id: 2,
        serverId: "local",
        kind: "session.output",
        subjectId: sessionId.uuidString,
        createdAt: "2026-07-18T00:00:01.000Z",
        payload: .object([
          "role": .string("user"),
          "messageId": .string(UUID().uuidString),
          "text": .string("run pwd"),
        ])
      ))
    await settleUntil { model.errorMessage != nil }
    #expect(userMessages(model).count == 1)
  }

  @Test("Blank prompts are ignored")
  func blankIgnored() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await model.send("   ")
    #expect(model.conversation.isEmpty)
    #expect(client.promptedTexts.isEmpty)
  }

  @Test("cancel is ignored unless a turn is in flight")
  func cancelOnlyWhileSending() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await model.cancel()
    #expect(client.cancelCount == 0)
  }

  @Test("Cancellation is single-flight and clears on the terminal event")
  func cancellationIsSingleFlight() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await model.send("keep working")
    #expect(model.isSending)

    async let first: Void = model.cancel()
    await settleUntil { client.cancelCount == 1 }
    async let duplicate: Void = model.cancel()
    client.emit(stopEnvelope(id: 9, sessionId: sessionId, stopReason: "cancelled"))
    _ = await (first, duplicate)

    #expect(client.cancelCount == 1)
    #expect(model.isSending == false)
    #expect(model.isCancelling == false)
  }

  @Test("Missed live cancellation terminal reconciles from durable history")
  func cancellationReconcilesFromDurableHistory() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await model.send("keep working")
    #expect(model.isSending)
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: false,
      stopReason: "cancelled"
    )

    await model.cancel()

    #expect(client.cancelCount == 1)
    #expect(model.isSending == false)
    #expect(model.errorMessage == nil)
  }

  @Test("Successful cancellation with a generating snapshot surfaces recovery")
  func cancellationGeneratingSnapshotSurfacesRecovery() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await model.send("keep working")
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: true,
      stopReason: nil
    )

    await model.cancel()

    #expect(model.isSending)
    #expect(model.errorMessage?.contains("server still reports this turn as running") == true)
  }

  @Test("Recovery reconciles only the turns that need it")
  func recoveryReconcileGuards() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: true,
      stopReason: nil,
      text: "partial answer"
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    await model.reconcileIfInFlight()
    await model.reconcileIfStalled()
    #expect(client.transcriptPageRequests.isEmpty)

    await model.send("keep working")
    #expect(model.isSending)
    let baseline = client.transcriptPageRequests.count

    await model.reconcileIfStalled()
    #expect(client.transcriptPageRequests.count == baseline)

    await model.reconcileIfInFlight()
    #expect(client.transcriptPageRequests.count == baseline + 1)
    #expect(model.isSending)

    model.isTakingLongerThanExpected = true
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: false,
      stopReason: "interrupted",
      text: "partial answer"
    )
    await model.reconcileIfStalled()
    #expect(model.isSending == false)
    #expect(model.isTakingLongerThanExpected == false)
  }

  @Test("Attachments allow empty text and ride the prompt to the server")
  func attachmentsRidePrompt() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    let attachment = Attachment(
      fileId: "file-1", name: "shot.png", mimeType: "image/png", sizeBytes: 3, kind: .image
    )

    await model.send("", attachments: [attachment])

    #expect(client.promptedTexts == [""])
    #expect(client.promptedAttachments == [[attachment.serverRef]])
    guard case let .user(user) = model.conversation.first else {
      Issue.record("expected user")
      return
    }
    #expect(user.attachments == [attachment])
  }
}

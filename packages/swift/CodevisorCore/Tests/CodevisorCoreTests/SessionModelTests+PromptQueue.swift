import Foundation
import Testing

@testable import CodevisorCore

extension SessionModelTests {
  @Test("Queued message updates trim input and report transport failures")
  func queuedMessageUpdateResult() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    #expect(!(await model.promptQueue.update(id: "queue-1", text: "   ")))
    #expect(client.queueUpdates.isEmpty)

    #expect(await model.promptQueue.update(id: "queue-1", text: "  revised message  "))
    #expect(client.queueUpdates.count == 1)
    #expect(client.queueUpdates.first?.id == "queue-1")
    #expect(client.queueUpdates.first?.text == "revised message")

    client.failNextQueueMutation()
    #expect(!(await model.promptQueue.update(id: "queue-1", text: "fails")))
    #expect(model.errorMessage != nil)
  }

  @Test("Queued message deletion reports success and transport failures")
  func queuedMessageDeleteResult() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    #expect(await model.promptQueue.delete(id: "queue-1"))
    #expect(client.queueDeletes == ["queue-1"])

    client.failNextQueueMutation()
    #expect(!(await model.promptQueue.delete(id: "queue-2")))
    #expect(model.errorMessage != nil)
  }

  @Test("Queued message reordering reports success and transport failures")
  func queuedMessageReorderResult() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    #expect(await model.promptQueue.reorder(ids: ["queue-2", "queue-1"]))
    #expect(client.queueReorders == [["queue-2", "queue-1"]])
    #expect(!(await model.promptQueue.reorder(ids: ["queue-1", "queue-1"])))

    model.promptQueue.apply([Self.queued("queue-1"), Self.queued("queue-2")])
    client.failNextQueueMutation()
    #expect(!(await model.promptQueue.reorder(ids: ["queue-2", "queue-1"])))
    #expect(model.errorMessage != nil)
    #expect(model.queuedPrompts.map(\.id) == ["queue-1", "queue-2"])
  }

  private static func queued(_ id: String) -> ServerPromptQueueItem {
    ServerPromptQueueItem(
      id: id, sessionId: "session", text: id,
      createdAt: "2026-10-20T00:00:00.000Z", updatedAt: "2026-10-20T00:00:00.000Z")
  }

  @Test("A failed prompt queue load clears the queue")
  func failedQueueLoadClearsQueue() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    defer { model.shutdown() }
    model.promptQueue.apply([Self.queued("queue-1")])
    client.failNextPromptQueue()

    _ = await model.loadHistoryForConnectionRecovery()

    #expect(client.promptQueueRequestCount == 1)
    #expect(model.queuedPrompts.isEmpty)
    #expect(model.errorMessage == nil)
  }

  @Test("A failed deferred queue load keeps a queue that changed while it was in flight")
  func failedDeferredQueueLoadKeepsNewerQueue() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.failNextPromptQueue()
    let (gate, releaseQueue) = AsyncStream.makeStream(of: Void.self)
    client.holdPromptQueue(until: gate)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    defer { model.shutdown() }

    await model.loadHistoryForInitialDisplay()
    await settleUntil { client.promptQueueRequestCount == 1 }
    model.promptQueue.apply([Self.queued("queue-1")])
    releaseQueue.yield()
    releaseQueue.finish()
    await model.promptQueue.loadTask?.value

    #expect(model.queuedPrompts.map(\.id) == ["queue-1"])
  }

  @Test("Shutting down drops a deferred queue load that has not returned")
  func shutdownDropsDeferredQueueLoad() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.setPromptQueueResponse([Self.queued("queue-1")])
    let (gate, releaseQueue) = AsyncStream.makeStream(of: Void.self)
    client.holdPromptQueue(until: gate)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    await model.loadHistoryForInitialDisplay()
    await settleUntil { client.promptQueueRequestCount == 1 }
    let pendingLoad = model.promptQueue.loadTask
    model.shutdown()
    releaseQueue.yield()
    releaseQueue.finish()
    await pendingLoad?.value

    #expect(model.promptQueue.loadTask == nil)
    #expect(model.queuedPrompts.isEmpty)
  }

  @Test("A deferred queue load keeps its session model alive until the queue returns")
  func deferredQueueLoadKeepsModelAlive() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let (gate, releaseQueue) = AsyncStream.makeStream(of: Void.self)
    client.holdPromptQueue(until: gate)
    let pending = await abandonedDeferredQueueLoad(client: client, sessionId: sessionId)

    #expect(pending.model() != nil)

    releaseQueue.yield()
    releaseQueue.finish()
    await pending.load?.value

    #expect(pending.model() == nil)
  }

  private func abandonedDeferredQueueLoad(
    client: FakeSessionServerClient, sessionId: UUID
  ) async -> (load: Task<Void, Never>?, model: () -> SessionModel?) {
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await model.loadHistoryForInitialDisplay()
    await settleUntil { client.promptQueueRequestCount == 1 }
    return (model.promptQueue.loadTask, { [weak model] in model })
  }

  @Test("Each queued message that leaves the queue is promoted once when its echo arrives")
  func queuedMessagePromotedOnce() {
    let sessionId = UUID()
    let model = SessionModel(
      serverTransport: ServerSessionTransport(
        client: FakeSessionServerClient(sessionId: sessionId), sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    defer { model.shutdown() }
    var promoted: [UUID?] = []
    model.onQueuedPromptPromoted = { promoted.append($0) }
    let first = UUID()
    let second = UUID()
    let neverQueued = UUID()

    model.promptQueue.apply([Self.queued(first.uuidString), Self.queued(second.uuidString)])
    model.promptQueue.apply([Self.queued(second.uuidString)])
    model.apply(.userMessage(id: neverQueued.uuidString, text: "direct", attachments: []))
    model.apply(.userMessage(id: first.uuidString, text: first.uuidString, attachments: []))
    model.apply(.userMessage(id: first.uuidString, text: first.uuidString, attachments: []))

    #expect(promoted == [first])
    #expect(model.queuedPrompts.map(\.id) == [second.uuidString])
  }

  @Test("Sending a queued message now reports success and transport failures, but not a message that already left")
  func queuedMessageSendNowResult() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    #expect(await model.promptQueue.sendNow(id: "queue-1"))
    #expect(client.promptDelivery.sendsNow == ["queue-1"])

    client.promptDelivery.failNextSendNow(with: CodevisorServerClientError.httpStatus(404, "gone"))
    #expect(!(await model.promptQueue.sendNow(id: "queue-2")))
    #expect(model.errorMessage == nil)

    client.promptDelivery.failNextSendNow()
    #expect(!(await model.promptQueue.sendNow(id: "queue-3")))
    #expect(model.errorMessage != nil)
  }

  @Test("Messages sent during a turn carry their delivery and report when they were not steered")
  func messagesDuringTurnCarryDelivery() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    var notSteered: [UUID] = []
    model.onPromptNotSteered = { notSteered.append($0) }
    let steered = UserMessage(text: "steer this")
    let queued = UserMessage(text: "queue this")
    let declined = UserMessage(text: "steer declined")

    await model.send("first")
    client.promptDelivery.answerSteers(with: "steered")
    await model.send(steered)
    await model.send(queued, delivery: .queue)
    client.promptDelivery.answerSteers(with: "queued")
    await model.send(declined)

    #expect(client.promptDelivery.deliveries == [.steer, .queue, .steer])
    #expect(client.promptedMessageIds.suffix(3) == [steered, queued, declined].map { $0.id.uuidString.lowercased() })
    #expect(notSteered == [queued.id, declined.id])
  }
}

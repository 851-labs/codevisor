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

    #expect(!(await model.updateQueuedPrompt(id: "queue-1", text: "   ")))
    #expect(client.queueUpdates.isEmpty)

    #expect(await model.updateQueuedPrompt(id: "queue-1", text: "  revised message  "))
    #expect(client.queueUpdates.count == 1)
    #expect(client.queueUpdates.first?.id == "queue-1")
    #expect(client.queueUpdates.first?.text == "revised message")

    client.failNextQueueMutation()
    #expect(!(await model.updateQueuedPrompt(id: "queue-1", text: "fails")))
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

    #expect(await model.deleteQueuedPrompt(id: "queue-1"))
    #expect(client.queueDeletes == ["queue-1"])

    client.failNextQueueMutation()
    #expect(!(await model.deleteQueuedPrompt(id: "queue-2")))
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

    #expect(await model.reorderQueuedPrompts(ids: ["queue-2", "queue-1"]))
    #expect(client.queueReorders == [["queue-2", "queue-1"]])
    #expect(!(await model.reorderQueuedPrompts(ids: ["queue-1", "queue-1"])))

    model.applyQueuedPromptSnapshot([Self.queued("queue-1"), Self.queued("queue-2")])
    client.failNextQueueMutation()
    #expect(!(await model.reorderQueuedPrompts(ids: ["queue-2", "queue-1"])))
    #expect(model.errorMessage != nil)
    #expect(model.queuedPrompts.map(\.id) == ["queue-1", "queue-2"])
  }

  private static func queued(_ id: String) -> ServerPromptQueueItem {
    ServerPromptQueueItem(
      id: id, sessionId: "session", text: id,
      createdAt: "2026-10-20T00:00:00.000Z", updatedAt: "2026-10-20T00:00:00.000Z")
  }

  @Test("Sending a queued message now reports success and transport failures, but not a message that already left")
  func queuedMessageSendNowResult() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    #expect(await model.sendQueuedPromptNow(id: "queue-1"))
    #expect(client.promptDelivery.sendsNow == ["queue-1"])

    client.promptDelivery.failNextSendNow(with: CodevisorServerClientError.httpStatus(404, "gone"))
    #expect(!(await model.sendQueuedPromptNow(id: "queue-2")))
    #expect(model.errorMessage == nil)

    client.promptDelivery.failNextSendNow()
    #expect(!(await model.sendQueuedPromptNow(id: "queue-3")))
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

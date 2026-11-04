import ACPKit
import Foundation
import Testing
import TranscriptKit

@testable import CodevisorCore

extension SessionModelTests {
  private final class SendClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
      lock.withLock { current += seconds }
    }
  }

  @Test("A steer Claude reads at its next step stays a bubble saying Waiting on tool until it reaches the transcript")
  func nextStepSteerWaitsAsABubble() async {
    let (client, model) = await busySteeringModel(clock: SendClock())
    let steer = UserMessage(text: "also bump the version")
    client.setPromptQueueResponse([steeredItem(steer, client)])

    await model.send(steer)
    await settleUntil { model.transcriptDeliveries[steer.id] == .awaitingStep }

    #expect(model.outgoingMessages.isEmpty)
    #expect(model.transcriptPendingMessages.map(\.id) == [steer.id])
    #expect(model.transcriptDeliveries == [steer.id: .awaitingStep])

    client.setPromptQueueResponse([])
    model.promptQueue.apply([])

    #expect(model.transcriptPendingMessages.map(\.id) == [steer.id])
    #expect(model.transcriptDeliveries.isEmpty)

    client.emit(steerEcho(1, client.sessionId, steer))
    await settleUntil { userMessages(model).contains { $0.id == steer.id } }

    #expect(model.transcriptPendingMessages.isEmpty)
    model.shutdown()
  }

  @Test("A message sent while a steer waits shows below the steer bubble, in send order")
  func laterSendShowsBelowAWaitingSteer() async {
    let clock = SendClock()
    let (client, model) = await busySteeringModel(clock: clock)
    let steer = UserMessage(text: "also bump the version")
    let later = UserMessage(text: "and update the changelog")
    client.setPromptQueueResponse([steeredItem(steer, client)])
    await model.send(steer)
    await settleUntil { model.transcriptDeliveries[steer.id] == .awaitingStep }

    clock.advance(by: 5)
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    client.holdPrompts(until: gate)
    let send = Task { await model.send(later) }
    await settleUntil { model.outgoingMessages.contains { $0.message.id == later.id } }

    #expect(model.transcriptPendingMessages.map(\.id) == [steer.id, later.id])

    release.finish()
    await send.value
    model.shutdown()
  }

  @Test("Delete takes a waiting steer back, and the bubble leaves without being read as delivered")
  func deletingAWaitingSteerWithdrawsIt() async {
    let (client, model) = await busySteeringModel(clock: SendClock())
    let steer = UserMessage(text: "actually, skip the tests")
    let id = steer.id.uuidString.lowercased()
    client.setPromptQueueResponse([steeredItem(steer, client)])
    await model.send(steer)
    await settleUntil { model.transcriptDeliveries[steer.id] == .awaitingStep }

    let withdrawn = await model.withdrawSteer(messageID: steer.id)
    client.setPromptQueueResponse([])
    model.promptQueue.apply([])

    #expect(withdrawn)
    #expect(client.queueDeletes == [id])
    #expect(model.transcriptPendingMessages.isEmpty)
    #expect(model.transcriptDeliveries.isEmpty)
    model.shutdown()
  }

  @Test("Delete fails quietly once the steer has reached the agent, and the bubble keeps waiting")
  func deletingASteerTheAgentHasFails() async {
    let (client, model) = await busySteeringModel(clock: SendClock())
    let steer = UserMessage(text: "actually, skip the tests")
    client.setPromptQueueResponse([steeredItem(steer, client)])
    await model.send(steer)
    await settleUntil { model.transcriptDeliveries[steer.id] == .awaitingStep }
    client.promptDelivery.conflictNextDelete()

    let withdrawn = await model.withdrawSteer(messageID: steer.id)

    #expect(!withdrawn)
    #expect(model.errorMessage == nil)
    #expect(client.queueDeletes.isEmpty)
    #expect(model.transcriptPendingMessages.map(\.id) == [steer.id])
    #expect(model.transcriptDeliveries == [steer.id: .awaitingStep])
    model.shutdown()
  }

  private func busySteeringModel(clock: SendClock) async -> (FakeSessionServerClient, SessionModel) {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString,
      now: { clock.now }
    )
    model.sendRetryDelays = [.zero, .zero]
    model.sendingNoticeDelay = .seconds(3600)
    await model.send("first")
    #expect(model.isSending)
    client.promptDelivery.answerSteers(with: "steered")
    return (client, model)
  }

  private func steeredItem(_ message: UserMessage, _ client: FakeSessionServerClient) -> ServerPromptQueueItem {
    var item = ServerPromptQueueItem(
      id: message.id.uuidString.lowercased(), sessionId: client.sessionId.uuidString, text: message.text,
      createdAt: "2027-01-15T08:00:00.000Z", updatedAt: "2027-01-15T08:00:00.000Z")
    item.steered = true
    return item
  }

  private func steerEcho(_ id: Int, _ sessionId: UUID, _ message: UserMessage) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: id, serverId: "local", kind: "session.output", subjectId: sessionId.uuidString,
      createdAt: "2027-01-15T08:00:01.000Z",
      payload: .object([
        "role": .string("user"),
        "messageId": .string(message.id.uuidString.lowercased()),
        "text": .string(message.text),
      ]))
  }
}

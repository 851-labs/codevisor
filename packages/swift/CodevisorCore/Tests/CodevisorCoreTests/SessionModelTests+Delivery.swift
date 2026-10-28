import ACPKit
import Foundation
import Testing
import TranscriptKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("A steer the server never took stays in the transcript as Not Delivered, and Try Again delivers it")
  func failedSteerStaysAsNotDelivered() async {
    let (client, model) = await busyNormalModel()
    client.promptDelivery.answerSteers(with: "steered")
    client.sendAttempts.failuresLeft = 3
    let message = UserMessage(text: "also check the tests")
    let id = message.id.uuidString.lowercased()

    await model.send(message)

    #expect(client.sendAttempts.actionIds.dropFirst() == [id, id, id])
    #expect(model.transcriptOutgoingMessages.map(\.text) == ["also check the tests"])
    #expect(model.transcriptDeliveries == [message.id: .failed(reason: SessionModel.undeliveredReason)])
    #expect(model.errorMessage == nil)

    await model.retryUnsentMessage(id: message.id)

    #expect(client.sendAttempts.actionIds.dropFirst() == [id, id, id, id])
    #expect(model.transcriptOutgoingMessages.map(\.text) == ["also check the tests"])
    #expect(model.transcriptDeliveries.isEmpty)

    client.emit(userEcho(1, client.sessionId, message))
    await settleUntil { model.outgoingMessages.isEmpty }
    #expect(userMessages(model).map(\.text) == ["first", "also check the tests"])
    model.shutdown()
  }

  @Test("A queued message only shows in the transcript once it fails, and Delete removes it")
  func failedQueueSendShowsOnlyWhenFailed() async {
    let (client, model) = await busyNormalModel()
    client.promptFailure = .httpStatus(409, "Conflict")
    let message = UserMessage(text: "after that, ship it")

    let send = Task { await model.send(message, delivery: .queue) }
    await client.promptRequests.wait(for: 2)
    #expect(model.transcriptOutgoingMessages.isEmpty)
    await send.value

    #expect(model.transcriptOutgoingMessages.map(\.text) == ["after that, ship it"])
    #expect(model.transcriptDeliveries == [message.id: .failed(reason: SessionModel.undeliveredReason)])

    model.deleteUnsentMessage(id: message.id)

    #expect(model.transcriptOutgoingMessages.isEmpty)
    #expect(model.transcriptDeliveries.isEmpty)
    model.shutdown()
  }

  @Test("A dropped queue send is retried with the same action id and leaves once it is in the queue")
  func droppedQueueSendLandsInQueue() async {
    let (client, model) = await busyNormalModel()
    client.sendAttempts.failuresLeft = 1
    let message = UserMessage(text: "queue me")
    let id = message.id.uuidString.lowercased()

    await model.send(message, delivery: .queue)

    #expect(client.sendAttempts.actionIds.dropFirst() == [id, id])
    #expect(model.transcriptOutgoingMessages.isEmpty)
    model.promptQueue.apply([
      ServerPromptQueueItem(
        id: id, sessionId: client.sessionId.uuidString, text: "queue me",
        createdAt: "2026-10-21T00:00:00.000Z", updatedAt: "2026-10-21T00:00:00.000Z")
    ])
    #expect(model.outgoingMessages.isEmpty)
    model.shutdown()
  }

  @Test("A send that hasn't reached the server yet says Sending, whether or not the agent is working")
  func slowSendsSaySending() async {
    let (client, model) = normalModel()
    model.sendingNoticeDelay = .zero
    let idle = UserMessage(text: "start")
    let busy = UserMessage(text: "and this")

    let (idleGate, releaseIdle) = AsyncStream.makeStream(of: Void.self)
    client.holdPrompts(until: idleGate)
    let first = Task { await model.send(idle) }
    await client.promptRequests.wait()
    await settleUntil { model.transcriptDeliveries[idle.id] == .sending }
    releaseIdle.finish()
    await first.value
    #expect(model.transcriptDeliveries.isEmpty)

    let (busyGate, releaseBusy) = AsyncStream.makeStream(of: Void.self)
    client.holdPrompts(until: busyGate)
    let second = Task { await model.send(busy) }
    await client.promptRequests.wait(for: 2)
    await settleUntil { model.transcriptDeliveries[busy.id] == .sending }
    #expect(model.transcriptOutgoingMessages.map(\.text) == ["and this"])
    releaseBusy.finish()
    await second.value

    #expect(model.transcriptDeliveries.isEmpty)
    model.shutdown()
  }

  @Test("An idle send that blips recovers on its own without a failed turn")
  func idleSendRecoversFromABlip() async {
    let (client, model) = normalModel()
    client.sendAttempts.failuresLeft = 2
    let message = UserMessage(text: "fix the build")
    let id = message.id.uuidString.lowercased()

    await model.send(message)

    #expect(client.sendAttempts.actionIds == [id, id, id])
    #expect(model.errorMessage == nil)
    #expect(userMessages(model).map(\.text) == ["fix the build"])
    #expect(!failedTurn(model))
    model.shutdown()
  }

  @Test("An idle send that can't reach the server fails its turn, then resends itself once the connection is back")
  func idleSendResendsAfterReconnect() async {
    let (client, model) = normalModel()
    client.sendAttempts.failuresLeft = 3
    let message = UserMessage(text: "fix the build")
    let id = message.id.uuidString.lowercased()

    await model.send(message)

    #expect(failedTurn(model))
    #expect(model.errorMessage == "Machine unreachable")
    #expect(!model.isSending)

    model.apply(.synchronization(.caughtUp))

    await settleUntil { model.isSending }
    await settleUntil { model.unreachedSend == nil }
    #expect(client.sendAttempts.actionIds == [id, id, id, id])
    #expect(model.errorMessage == nil)
    model.shutdown()
  }

  @Test("Retrying a turn that failed after the server took it sends a new request, so the server runs it again")
  func retryAfterAgentFailureUsesAFreshAction() async {
    let (client, model) = normalModel()
    client.echoOnPrompt = true
    let message = UserMessage(text: "fix the build")

    await model.send(message)
    #expect(!model.isSending)
    await model.retryResponse(to: message)

    let actions = client.sendAttempts.actionIds
    #expect(actions.count == 2)
    #expect(actions.first == message.id.uuidString.lowercased())
    #expect(actions.last != actions.first)
    model.shutdown()
  }

  @Test("An idle send whose acknowledgement was lost isn't failed when the server already has it")
  func idleSendWithLostAcknowledgement() async {
    let (client, model) = normalModel()
    let message = UserMessage(text: "fix the build")
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [
        ServerTranscriptItem(
          id: UUID().uuidString, sessionId: client.sessionId.uuidString, sequence: 1, role: .user,
          text: "fix the build", createdAt: "2026-10-21T00:00:00.000Z", updatedAt: "2026-10-21T00:00:00.000Z",
          isGenerating: false, hasDetails: false, messageId: message.id.uuidString.lowercased(), revision: 1)
      ],
      hasMore: false,
      eventCursor: 1
    )
    client.promptFailure = .httpStatus(504, "Timed out")

    await model.send(message)

    #expect(!failedTurn(model))
    #expect(model.errorMessage == nil)
    model.shutdown()
  }

  private func normalModel() -> (FakeSessionServerClient, SessionModel) {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    model.sendRetryDelays = [.zero, .zero]
    model.sendingNoticeDelay = .seconds(3600)
    return (client, model)
  }

  private func busyNormalModel() async -> (FakeSessionServerClient, SessionModel) {
    let (client, model) = normalModel()
    await model.send("first")
    #expect(model.isSending)
    return (client, model)
  }

  private func failedTurn(_ model: SessionModel) -> Bool {
    model.conversation.contains { item in
      if case let .assistant(message) = item { return message.turn.stopDetail != nil }
      return false
    }
  }

  private func userEcho(_ id: Int, _ sessionId: UUID, _ message: UserMessage) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: id, serverId: "local", kind: "session.output", subjectId: sessionId.uuidString,
      createdAt: "2026-10-21T00:00:00.000Z",
      payload: .object([
        "role": .string("user"),
        "messageId": .string(message.id.uuidString.lowercased()),
        "text": .string(message.text),
      ]))
  }
}

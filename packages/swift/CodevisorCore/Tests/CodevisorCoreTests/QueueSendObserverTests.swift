import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Noticing a message sent into the queue")
struct QueueSendObserverTests {
  @Test("Opening a chat that already has queued messages is not a send")
  func openingIsNotASend() async {
    let controller = Self.workingController()
    await Self.queue("sent before opening", in: controller)
    var observer = QueueSendObserver()

    let sent = observer.sentSinceLastCheck(in: controller)

    #expect(!sent)
  }

  @Test("A message sent into the queue counts once")
  func queueSendCountsOnce() async {
    let controller = Self.workingController()
    var observer = QueueSendObserver()
    _ = observer.sentSinceLastCheck(in: controller)

    await Self.queue("do this next", in: controller)

    let first = observer.sentSinceLastCheck(in: controller)
    let second = observer.sentSinceLastCheck(in: controller)

    #expect(first)
    #expect(!second)
  }

  @Test("A send that starts a turn is not a queue send")
  func idleSendIsNotAQueueSend() async {
    let controller = Self.workingController()
    controller.model?.isSending = false
    var observer = QueueSendObserver()
    _ = observer.sentSinceLastCheck(in: controller)

    controller.composerText = "start working"
    await controller.send(delivery: .queue)
    let sent = observer.sentSinceLastCheck(in: controller)

    #expect(!sent)
  }

  @Test("Switching to another chat that has queue sends is not a send")
  func switchingChatsIsNotASend() async {
    let first = Self.workingController()
    let second = Self.workingController()
    var observer = QueueSendObserver()
    _ = observer.sentSinceLastCheck(in: first)
    await Self.queue("queued in the other chat", in: second)

    let sent = observer.sentSinceLastCheck(in: second)

    #expect(!sent)
  }

  private static func workingController() -> SessionController {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    model.isSending = true
    return SessionController.preview(model: model)
  }

  private static func queue(_ text: String, in controller: SessionController) async {
    controller.composerText = text
    await controller.send(delivery: .queue)
  }
}

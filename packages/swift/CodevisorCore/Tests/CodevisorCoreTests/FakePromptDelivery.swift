import Foundation

@testable import CodevisorCore

final class FakePromptDelivery: @unchecked Sendable {
  private let lock = NSLock()
  private var _deliveries: [ServerPromptDelivery] = []
  private var _steerOutcome: String?
  private var _sendsNow: [String] = []
  private var _sendNowFailures: [any Error] = []

  var deliveries: [ServerPromptDelivery] { lock.withLock { _deliveries } }
  var sendsNow: [String] { lock.withLock { _sendsNow } }

  func answerSteers(with delivered: String) {
    lock.withLock { _steerOutcome = delivered }
  }

  func failNextSendNow(with error: any Error = URLError(.networkConnectionLost)) {
    lock.withLock { _sendNowFailures.append(error) }
  }

  func outcome(for delivery: ServerPromptDelivery) -> String? {
    lock.withLock {
      _deliveries.append(delivery)
      return delivery == .steer ? _steerOutcome : "queued"
    }
  }

  func sendNow(sessionId: UUID, queueItemId: String) throws -> ServerPromptAccepted {
    let failure: (any Error)? = lock.withLock {
      guard !_sendNowFailures.isEmpty else {
        _sendsNow.append(queueItemId)
        return nil
      }
      return _sendNowFailures.removeFirst()
    }
    if let failure { throw failure }
    return ServerPromptAccepted(
      accepted: true, sessionId: sessionId.uuidString, queueItemId: queueItemId, delivered: "steered")
  }
}

extension FakeSessionServerClient {
  func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?,
    clientId: String?, delivery: ServerPromptDelivery
  ) async throws -> ServerPromptAccepted {
    var accepted = try await promptSession(
      id: id, text: text, attachments: attachments, messageId: messageId, clientId: clientId
    )
    accepted.delivered = promptDelivery.outcome(for: delivery)
    return accepted
  }

  func sendQueuedPromptNow(sessionId: UUID, queueItemId: String) async throws -> ServerPromptAccepted {
    try promptDelivery.sendNow(sessionId: sessionId, queueItemId: queueItemId)
  }
}

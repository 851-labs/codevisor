import CodevisorTestSupport
import CodevisorClient
import Foundation

final class FakeSendAttempts: @unchecked Sendable {
  private let lock = NSLock()
  private var _actionIds: [String] = []
  private var _failuresLeft = 0
  var reconnection: AsyncStream<Void>?
  let connectionWaits = TestSignal()

  var actionIds: [String] { lock.withLock { _actionIds } }

  var failuresLeft: Int {
    get { lock.withLock { _failuresLeft } }
    set { lock.withLock { _failuresLeft = newValue } }
  }

  func attempt(_ actionId: String) throws {
    let fails = lock.withLock {
      _actionIds.append(actionId)
      defer { _failuresLeft = max(0, _failuresLeft - 1) }
      return _failuresLeft > 0
    }
    if fails { throw URLError(.networkConnectionLost) }
  }
}

extension FakeSessionServerClient {
  func waitUntilConnected() async -> Bool {
    sendAttempts.connectionWaits.signal()
    guard let reconnection = sendAttempts.reconnection else { return false }
    for await _ in reconnection {}
    return true
  }

  func reconnectsAtOnce() {
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    continuation.finish()
    sendAttempts.reconnection = stream
  }

  func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?,
    clientId: String?, delivery: ServerPromptDelivery?, clientActionId: String
  ) async throws -> ServerPromptAccepted {
    try sendAttempts.attempt(clientActionId)
    guard let delivery else {
      return try await promptSession(
        id: id, text: text, attachments: attachments, messageId: messageId, clientId: clientId
      )
    }
    return try await promptSession(
      id: id, text: text, attachments: attachments, messageId: messageId, clientId: clientId,
      delivery: delivery
    )
  }
}

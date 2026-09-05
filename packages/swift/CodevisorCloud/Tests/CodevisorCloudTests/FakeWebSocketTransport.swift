import CodevisorTestSupport
import Observation
import Foundation
import CodevisorClient
import CodevisorProtocol
@testable import CodevisorCloud

// MARK: - Fake WebSocket seam

/// A scripted WebSocket connection: the test (or a scripted machine) feeds
/// inbound messages through `push`/`finish`, and every outbound send is both
/// recorded and forwarded to `onSend`.
@Observable
final class FakeWebSocketConnection: ServerWebSocketConnecting, @unchecked Sendable {
  private let lock = NSLock()
  private let inbound: AsyncThrowingStream<ServerWebSocketMessage, any Error>
  private let inboundContinuation: AsyncThrowingStream<ServerWebSocketMessage, any Error>.Continuation
  @ObservationIgnored private var iterator: AsyncThrowingStream<ServerWebSocketMessage, any Error>.Iterator
  private var sentMessages: [ServerWebSocketMessage] = []
  private var pushedCount = 0
  let receiving = TestSignal()
  let cancelled = TestSignal()
  var onSend: (@Sendable (ServerWebSocketMessage) -> Void)?
  var closeCodeOnDisconnect: URLSessionWebSocketTask.CloseCode = .invalid
  var failsSends = false

  init() {
    (inbound, inboundContinuation) =
      AsyncThrowingStream<ServerWebSocketMessage, any Error>.makeStream()
    iterator = inbound.makeAsyncIterator()
  }

  var sent: [ServerWebSocketMessage] {
    lock.withLock { sentMessages }
  }

  var sentTexts: [String] {
    sent.compactMap {
      if case let .string(text) = $0 { text } else { nil }
    }
  }

  func push(_ message: ServerWebSocketMessage) {
    lock.withLock { pushedCount += 1 }
    inboundContinuation.yield(message)
  }

  func pushJSON(_ json: String) {
    push(.string(json))
  }

  /// Ends the connection: the client's pending/next receive throws.
  func disconnect() {
    inboundContinuation.finish(throwing: URLError(.networkConnectionLost))
  }

  func send(_ message: ServerWebSocketMessage) async throws {
    if failsSends { throw URLError(.networkConnectionLost) }
    lock.withLock { sentMessages.append(message) }
    onSend?(message)
  }

  func receive() async throws -> ServerWebSocketMessage {
    receiving.signal()
    guard let message = try await iterator.next() else {
      throw URLError(.networkConnectionLost)
    }
    return message
  }

  func drain() async {
    await receiving.wait(for: lock.withLock { pushedCount + 1 })
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    inboundContinuation.finish(throwing: URLError(.cancelled))
    cancelled.signal()
  }

  var closeCode: URLSessionWebSocketTask.CloseCode {
    closeCodeOnDisconnect
  }
}

/// Hands out connections built by `makeConnection` — one per connect call.
@Observable
final class FakeWebSocketTransport: ServerWebSocketTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let makeConnection: @Sendable (URLRequest) -> any ServerWebSocketConnecting
  private var requestedURLs: [URL] = []

  init(makeConnection: @escaping @Sendable (URLRequest) -> any ServerWebSocketConnecting) {
    self.makeConnection = makeConnection
  }

  var requests: [URL] {
    lock.withLock { requestedURLs }
  }

  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
    if let url = request.url {
      lock.withLock { requestedURLs.append(url) }
    }
    return makeConnection(request)
  }
}

// MARK: - Scripted hub + machine

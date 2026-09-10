import Foundation
import Testing
import CodevisorTestSupport
@testable import CodevisorCore

private final class ControlSocket: ServerWebSocketConnecting, @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [ServerWebSocketMessage] = []
  private var waiter: CheckedContinuation<ServerWebSocketMessage, Error>?
  private var closed = false
  private var sent: [ServerWebSocketMessage] = []
  let didSend = TestSignal()

  var closeCode: URLSessionWebSocketTask.CloseCode { lock.withLock { closed ? .goingAway : .invalid } }
  var output: [ServerWebSocketMessage] { lock.withLock { sent } }
  func send(_ message: ServerWebSocketMessage) async throws {
    lock.withLock { sent.append(message) }
    didSend.signal()
  }
  func receive() async throws -> ServerWebSocketMessage {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock {
        if closed {
          continuation.resume(throwing: CancellationError())
        } else if !messages.isEmpty {
          continuation.resume(returning: messages.removeFirst())
        } else {
          waiter = continuation
        }
      }
    }
  }
  func deliver(_ message: ServerWebSocketMessage) {
    lock.withLock {
      if let waiter {
        self.waiter = nil
        waiter.resume(returning: message)
      } else {
        messages.append(message)
      }
    }
  }
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    lock.withLock {
      closed = true
      waiter?.resume(throwing: CancellationError())
      waiter = nil
    }
  }
}

private final class ControlTransport: ServerWebSocketTransport, @unchecked Sendable {
  let socket = ControlSocket()
  private let lock = NSLock()
  private var request: URLRequest?
  var connectedRequest: URLRequest? { lock.withLock { request } }
  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
    lock.withLock { self.request = request }
    return socket
  }
}

@MainActor
struct ClientControlTransportTests {
  @Test("The control channel uses authenticated transport and closes on window cancellation")
  func transportLifecycle() async throws {
    let transport = ControlTransport()
    let id = UUID()
    let config = CodevisorServerConfig(
      baseURL: URL(string: "https://fixture.invalid")!, bearerToken: "fixture-token",
      webSocketTransport: transport
    )
    let task = Task {
      await ClientControlConnection.run(
        clientId: id, name: "Fixture", platform: "macos", config: config,
        context: { NativeClientContext(isActive: true, workspaceId: nil, workspaces: []) },
        navigate: { _ in Issue.record("Context reads must not navigate") }
      )
    }
    await transport.socket.didSend.wait()
    let request = try #require(transport.connectedRequest)
    #expect(request.url?.scheme == "wss")
    #expect(request.url?.path == "/v1/clients/\(id.uuidString.lowercased())/socket")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    transport.socket.deliver(.string(#"{"requestId":"context","method":"context"}"#))
    await transport.socket.didSend.wait(for: 2)
    task.cancel()
    await task.value
    #expect(transport.socket.closeCode == .goingAway)
    let data = try #require(
      transport.socket.output.last.flatMap { message -> Data? in
        if case let .data(data) = message { return data }
        return nil
      })
    let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(response["requestId"] as? String == "context")
    #expect((response["context"] as? [String: Any])?["isActive"] as? Bool == true)
  }
}

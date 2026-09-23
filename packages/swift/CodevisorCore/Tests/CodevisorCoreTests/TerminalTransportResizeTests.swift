import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

private final class RecordingSocket: ServerWebSocketConnecting, @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [ServerWebSocketMessage] = []
  private var waiter: CheckedContinuation<ServerWebSocketMessage, Error>?
  private var closed = false
  let didSend = TestSignal()

  var closeCode: URLSessionWebSocketTask.CloseCode { lock.withLock { closed ? .goingAway : .invalid } }
  var output: [ServerWebSocketMessage] { lock.withLock { sent } }

  func send(_ message: ServerWebSocketMessage) async throws {
    lock.withLock { sent.append(message) }
    didSend.signal()
  }

  /// Never delivers: the test only reads what the transport sends.
  func receive() async throws -> ServerWebSocketMessage {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock {
        if closed { continuation.resume(throwing: CancellationError()) } else { waiter = continuation }
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

private final class RecordingSocketTransport: ServerWebSocketTransport, @unchecked Sendable {
  let socket = RecordingSocket()
  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting { socket }
}

private struct CreatedTerminal: ServerRequestTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let body = Data(#"{"terminalId":"t","websocketPath":"/v1/terminals/t/ws","nextOutputSeq":0}"#.utf8)
    let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
    return (body, response)
  }
}

/// The shell must learn the renderer's real size even when the view lays
/// out before the terminal's socket exists; a stale width makes the shell
/// redraw its prompt over itself as the user types.
@MainActor
@Suite("Terminal transport resize")
struct TerminalTransportResizeTests {
  @Test("A resize requested before the socket connects is sent once it does")
  func resizeBeforeConnect() async throws {
    let sockets = RecordingSocketTransport()
    let transport = TerminalTransport(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: CreatedTerminal(),
        webSocketTransport: sockets
      ),
      onEvent: { _ in }
    )
    // The view's first layout reports its size while the terminal is
    // still being created with the placeholder size.
    transport.sendResize(cols: 142, rows: 48)
    try await transport.open(sessionId: "s", cwd: "/", cols: 80, rows: 24)
    // A keystroke after connecting: the resize must already be ahead of it.
    transport.sendInput("x")
    await sockets.socket.didSend.wait()

    let frame = try #require(sockets.socket.output.first)
    guard case let .string(text) = frame else {
      Issue.record("expected a text frame")
      return
    }
    let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(json["type"] as? String == "resize")
    #expect(json["cols"] as? Int == 142)
    #expect(json["rows"] as? Int == 48)
    transport.detach()
  }
}

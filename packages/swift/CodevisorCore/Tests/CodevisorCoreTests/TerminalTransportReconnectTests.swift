import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

/// Records sent frames; never delivers any.
private final class SilentSocket: ServerWebSocketConnecting, @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [String] = []
  private var waiter: CheckedContinuation<ServerWebSocketMessage, Error>?
  private var closed = false
  let didSend = TestSignal()

  var closeCode: URLSessionWebSocketTask.CloseCode { lock.withLock { closed ? .goingAway : .invalid } }
  var frames: [[String: Any]] {
    lock.withLock { sent }.compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
  }
  var isCancelled: Bool { lock.withLock { closed } }

  func send(_ message: ServerWebSocketMessage) async throws {
    if case let .string(text) = message { lock.withLock { sent.append(text) } }
    didSend.signal()
  }

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

/// A fresh socket per connection attempt, recording each replay cursor.
private final class FreshSockets: ServerWebSocketTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var opened: [SilentSocket] = []
  private var queries: [String] = []
  let didConnect = TestSignal()

  var sockets: [SilentSocket] { lock.withLock { opened } }
  var connectQueries: [String] { lock.withLock { queries } }

  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
    let socket = SilentSocket()
    lock.withLock {
      opened.append(socket)
      queries.append(request.url?.query ?? "")
    }
    didConnect.signal()
    return socket
  }
}

private struct CreatedTerminal: ServerRequestTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let body = Data(#"{"terminalId":"t","websocketPath":"/v1/terminals/t/ws","nextOutputSeq":0}"#.utf8)
    let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
    return (body, response)
  }
}

/// Keystrokes typed while the socket is down (the app coming back from the
/// background, a network handoff) must still reach the shell, in order.
@MainActor
@Suite("Terminal transport reconnect")
struct TerminalTransportReconnectTests {
  private func makeTransport(_ sockets: FreshSockets) -> TerminalTransport {
    TerminalTransport(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: CreatedTerminal(),
        webSocketTransport: sockets
      ),
      onEvent: { _ in }
    )
  }

  @Test("Input typed before the socket exists is sent on connect, in order, ahead of the resize")
  func queuesInputUntilConnected() async throws {
    let sockets = FreshSockets()
    let transport = makeTransport(sockets)
    transport.sendResize(cols: 100, rows: 30)
    transport.sendInput("l")
    transport.sendInput("s")
    try await transport.open(sessionId: "s", cwd: "/", cols: 80, rows: 24)
    let socket = try #require(sockets.sockets.first)
    await socket.didSend.wait(for: 3)

    let frames = socket.frames
    #expect(frames.map { $0["type"] as? String } == ["input", "input", "resize"])
    #expect(frames.compactMap { $0["data"] as? String } == ["l", "s"])
    let seqs = frames.compactMap { $0["clientSeq"] as? Int }
    #expect(seqs == seqs.sorted() && Set(seqs).count == 3)
    transport.detach()
  }

  @Test("A paste beyond the queue bound is dropped rather than buffered forever")
  func boundsQueuedInput() async throws {
    let sockets = FreshSockets()
    let transport = makeTransport(sockets)
    transport.sendInput(String(repeating: "x", count: TerminalTransport.pendingInputLimit + 1))
    transport.sendInput("ok")
    try await transport.open(sessionId: "s", cwd: "/", cols: 80, rows: 24)
    let socket = try #require(sockets.sockets.first)
    await socket.didSend.wait(for: 1)
    #expect(socket.frames.compactMap { $0["data"] as? String } == ["ok"])
    transport.detach()
  }

  @Test("reconnectNow replaces a possibly half-open socket and resumes from the last sequence")
  func reconnectsImmediately() async throws {
    let sockets = FreshSockets()
    let transport = makeTransport(sockets)
    try await transport.open(sessionId: "s", cwd: "/", cols: 80, rows: 24)
    transport.reconnectNow()
    await sockets.didConnect.wait(for: 2)

    #expect(sockets.sockets.count == 2)
    #expect(sockets.sockets[0].isCancelled)
    #expect(!sockets.sockets[1].isCancelled)
    #expect(sockets.connectQueries == ["lastOutputSeq=0&protocol=2", "lastOutputSeq=0&protocol=2"])

    // Detached transports stay down.
    transport.detach()
    transport.reconnectNow()
    transport.sendInput("ignored")
    #expect(sockets.sockets.count == 2)
  }
}

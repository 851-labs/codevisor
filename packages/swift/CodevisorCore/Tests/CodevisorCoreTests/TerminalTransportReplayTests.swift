import Foundation
import Testing

@testable import CodevisorCore

/// Delivers a fixed list of server frames, then waits until cancelled.
private final class ScriptedSocket: ServerWebSocketConnecting, @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [ServerWebSocketMessage]
  private var waiter: CheckedContinuation<ServerWebSocketMessage, Error>?
  private var closed = false

  private let failsWhenDrained: Bool

  /// `failsWhenDrained` drops the connection after the last frame, as a
  /// network loss or the app's suspension would.
  init(frames: [String], failsWhenDrained: Bool = false) {
    pending = frames.map { .string($0) }
    self.failsWhenDrained = failsWhenDrained
  }

  var closeCode: URLSessionWebSocketTask.CloseCode { lock.withLock { closed ? .goingAway : .invalid } }

  func send(_ message: ServerWebSocketMessage) async throws {}

  func receive() async throws -> ServerWebSocketMessage {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock {
        if !pending.isEmpty {
          continuation.resume(returning: pending.removeFirst())
        } else if closed || failsWhenDrained {
          continuation.resume(throwing: CancellationError())
        } else {
          waiter = continuation
        }
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

/// Hands out one scripted socket per connection attempt, recording the
/// replay cursor each asked for.
private final class ScriptedSocketTransport: ServerWebSocketTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var sockets: [ScriptedSocket]
  private var queries: [String] = []

  init(socket: ScriptedSocket) { sockets = [socket] }
  init(sockets: [ScriptedSocket]) { self.sockets = sockets }

  var connectQueries: [String] { lock.withLock { queries } }

  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
    lock.withLock {
      queries.append(request.url?.query ?? "")
      return sockets.count > 1 ? sockets.removeFirst() : sockets[0]
    }
  }
}

/// Answers each create request with the next head in turn, recording
/// whether it asked to attach only.
private final class TerminalHeads: ServerRequestTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var heads: [Int]
  private var attachOnly: [Bool] = []

  init(heads: [Int]) { self.heads = heads }

  var attachOnlyRequests: [Bool] { lock.withLock { attachOnly } }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
    let head = lock.withLock {
      attachOnly.append(body?["attachOnly"] as? Bool ?? false)
      return heads.count > 1 ? heads.removeFirst() : heads[0]
    }
    let json = #"{"terminalId":"t","websocketPath":"/v1/terminals/t/ws","nextOutputSeq":\#(head)}"#
    let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
    return (Data(json.utf8), response)
  }
}

/// A terminal that has produced two frames before this client attaches.
private struct TerminalWithHistory: ServerRequestTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let body = Data(#"{"terminalId":"t","websocketPath":"/v1/terminals/t/ws","nextOutputSeq":3}"#.utf8)
    let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
    return (body, response)
  }
}

/// Reattaching replays the terminal's history, including queries apps made
/// back then; the renderer must be able to tell that history from live
/// output so it doesn't answer those queries again into the shell.
@MainActor
@Suite("Terminal transport replay")
struct TerminalTransportReplayTests {
  @Test("History arrives as one replayed event; later output is live")
  func marksReplayedOutput() async throws {
    let socket = ScriptedSocket(frames: [
      #"{"type":"output","seq":1,"data":"\u001b]11;?\u0007"}"#,
      #"{"type":"output","seq":2,"data":"history"}"#,
      #"{"type":"output","seq":3,"data":"live"}"#,
    ])
    let (events, continuation) = AsyncStream<TerminalEvent>.makeStream()
    let transport = TerminalTransport(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: TerminalWithHistory(),
        webSocketTransport: ScriptedSocketTransport(socket: socket)
      ),
      onEvent: { continuation.yield($0) }
    )
    try await transport.open(sessionId: "s", cwd: "/", cols: 80, rows: 24)

    var received: [(String, Bool)] = []
    for await event in events {
      if case let .output(data, replayed) = event { received.append((data, replayed)) }
      if received.count == 2 { break }
    }
    transport.detach()

    #expect(received.map(\.0) == ["\u{1B}]11;?\u{07}history", "live"])
    #expect(received.map(\.1) == [true, false])
  }

  /// An idle shell produces no live output, so the history can't wait for
  /// any: its last frame releases it.
  @Test("History is delivered once complete, without waiting for live output", .timeLimit(.minutes(1)))
  func deliversCompleteHistory() async throws {
    let socket = ScriptedSocket(frames: [
      #"{"type":"output","seq":1,"data":"prompt "}"#,
      #"{"type":"output","seq":2,"data":"$ "}"#,
    ])
    let (events, continuation) = AsyncStream<TerminalEvent>.makeStream()
    let transport = TerminalTransport(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: TerminalWithHistory(),
        webSocketTransport: ScriptedSocketTransport(socket: socket)
      ),
      onEvent: { continuation.yield($0) }
    )
    try await transport.open(sessionId: "s", cwd: "/", cols: 80, rows: 24)

    var iterator = events.makeAsyncIterator()
    let event = await iterator.next()
    transport.detach()

    guard case let .output(data, replayed) = event else {
      Issue.record("expected output")
      return
    }
    #expect(data == "prompt $ ")
    #expect(replayed)
  }

  /// Output produced while the app was suspended or offline may include
  /// queries another client already answered; it is caught up in one piece
  /// like an attach's history, while what follows stays live.
  @Test("Output missed during a disconnect is caught up as history", .timeLimit(.minutes(1)))
  func catchesUpAfterReconnect() async throws {
    let sockets = ScriptedSocketTransport(sockets: [
      ScriptedSocket(frames: [#"{"type":"output","seq":1,"data":"before"}"#], failsWhenDrained: true),
      ScriptedSocket(frames: [
        #"{"type":"output","seq":2,"data":"missed "}"#,
        #"{"type":"output","seq":3,"data":"\u001b[c"}"#,
        #"{"type":"output","seq":4,"data":"live"}"#,
      ]),
    ])
    let heads = TerminalHeads(heads: [2, 4])
    let (events, continuation) = AsyncStream<TerminalEvent>.makeStream()
    let transport = TerminalTransport(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: heads,
        webSocketTransport: sockets
      ),
      sleep: { _ in },
      onEvent: { continuation.yield($0) }
    )
    try await transport.open(sessionId: "s", cwd: "/", cols: 80, rows: 24)

    var received: [(String, Bool)] = []
    for await event in events {
      if case let .output(data, replayed) = event { received.append((data, replayed)) }
      if received.count == 3 { break }
    }
    transport.detach()

    #expect(received.map(\.0) == ["before", "missed \u{1B}[c", "live"])
    #expect(received.map(\.1) == [true, true, false])
    // The reconnect resumes after what was received, having asked for the
    // head without spawning a shell.
    #expect(sockets.connectQueries == ["lastOutputSeq=0", "lastOutputSeq=1"])
    #expect(heads.attachOnlyRequests == [false, true])
  }
}

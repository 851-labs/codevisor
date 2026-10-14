import Foundation
import Testing

@testable import CodevisorCore

private final class ScriptedSocket: ServerWebSocketConnecting, @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [ServerWebSocketMessage]
  private var waiter: CheckedContinuation<ServerWebSocketMessage, Error>?
  private var closed = false

  private let failsWhenDrained: Bool

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

private struct TerminalWithHistory: ServerRequestTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let body = Data(#"{"terminalId":"t","websocketPath":"/v1/terminals/t/ws","nextOutputSeq":3}"#.utf8)
    let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
    return (body, response)
  }
}

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
      if case let .output(output, replayed) = event { received.append((output.text, replayed)) }
      if received.count == 2 { break }
    }
    transport.detach()

    #expect(received.map(\.0) == ["\u{1B}]11;?\u{07}history", "live"])
    #expect(received.map(\.1) == [true, false])
  }

  @Test("A reset reconstruction is delivered as replayed history", .timeLimit(.minutes(1)))
  func deliversResetAsReplayed() async throws {
    let socket = ScriptedSocket(frames: [
      #"{"type":"output","seq":1,"data":"superseded"}"#,
      #"{"type":"output","seq":7,"data":"\u001bcscreen","reset":true}"#,
      #"{"type":"output","seq":8,"data":"live"}"#,
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
      if case let .output(output, replayed) = event { received.append((output.text, replayed)) }
      if received.count == 2 { break }
    }
    transport.detach()

    #expect(received.map(\.0) == ["\u{1B}cscreen", "live"])
    #expect(received.map(\.1) == [true, false])
  }

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
    #expect(data.text == "prompt $ ")
    #expect(replayed)
  }

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
      if case let .output(output, replayed) = event { received.append((output.text, replayed)) }
      if received.count == 3 { break }
    }
    transport.detach()

    #expect(received.map(\.0) == ["before", "missed \u{1B}[c", "live"])
    #expect(received.map(\.1) == [true, true, false])
    #expect(sockets.connectQueries == ["lastOutputSeq=0&protocol=2", "lastOutputSeq=1&protocol=2"])
    #expect(heads.attachOnlyRequests == [false, true])
  }
}

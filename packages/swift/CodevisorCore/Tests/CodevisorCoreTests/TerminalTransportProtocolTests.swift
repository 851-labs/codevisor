import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

private final class ProtocolSocket: ServerWebSocketConnecting, @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [ServerWebSocketMessage]
  private var waiter: CheckedContinuation<ServerWebSocketMessage, Error>?
  private var closed = false
  private var sent: [String] = []
  let didSend = TestSignal()

  init(messages: [ServerWebSocketMessage]) { pending = messages }

  var closeCode: URLSessionWebSocketTask.CloseCode { lock.withLock { closed ? .goingAway : .invalid } }
  var sentFrames: [[String: Any]] {
    lock.withLock { sent }.compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
  }

  func send(_ message: ServerWebSocketMessage) async throws {
    if case let .string(text) = message { lock.withLock { sent.append(text) } }
    didSend.signal()
  }

  func receive() async throws -> ServerWebSocketMessage {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock {
        if !pending.isEmpty {
          continuation.resume(returning: pending.removeFirst())
        } else if closed {
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

private struct OneSocket: ServerWebSocketTransport {
  let socket: ProtocolSocket
  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting { socket }
}

private final class SocketSequence: ServerWebSocketTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var sockets: [ProtocolSocket]
  let didConnect = TestSignal()
  init(_ sockets: [ProtocolSocket]) { self.sockets = sockets }
  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
    let socket = lock.withLock { sockets.count > 1 ? sockets.removeFirst() : sockets[0] }
    didConnect.signal()
    return socket
  }
}

private struct FreshTerminal: ServerRequestTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let body = Data(#"{"terminalId":"t","websocketPath":"/v1/terminals/t/ws","nextOutputSeq":1}"#.utf8)
    let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
    return (body, response)
  }
}

private func binaryOutput(kind: UInt8, seq: UInt64, _ text: String) -> ServerWebSocketMessage {
  var bytes: [UInt8] = [kind]
  for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((seq >> UInt64(shift)) & 0xFF)) }
  bytes.append(contentsOf: Array(text.utf8))
  return .data(Data(bytes))
}

private struct ReconnectTiming: Sendable {
  let pingInterval: Duration
  let clock = TestClock()
  let reconnectWaiting = TestSignal()
  let releaseReconnect = TestSignal()

  func sleep(for duration: Duration) async throws {
    try Task.checkCancellation()
    if duration == pingInterval {
      try await clock.sleep(for: duration)
    } else {
      reconnectWaiting.signal()
      await releaseReconnect.wait()
      try Task.checkCancellation()
    }
  }
}

@MainActor
@Suite("Terminal transport protocol 2")
struct TerminalTransportProtocolTests {
  @Test("Binary output is delivered, and pings start once the server is ready", .timeLimit(.minutes(1)))
  func binaryOutputAndPings() async throws {
    let socket = ProtocolSocket(messages: [
      .string(#"{"type":"ready","seq":0,"protocol":2}"#),
      binaryOutput(kind: 1, seq: 1, "héllo"),
      .data(Data([9, 0])),
      .string(#"{"type":"pong","seq":0,"t":0}"#),
      binaryOutput(kind: 2, seq: 2, "\u{1B}cscreen"),
    ])
    let (events, continuation) = AsyncStream<TerminalEvent>.makeStream()
    let transport = TerminalTransport(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: FreshTerminal(),
        webSocketTransport: OneSocket(socket: socket)
      ),
      sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
      onEvent: { continuation.yield($0) }
    )
    try await transport.open(sessionId: "s", cwd: "/", cols: 80, rows: 24)

    var received: [(String, Bool)] = []
    for await event in events {
      if case let .output(output, replayed) = event { received.append((output.text, replayed)) }
      if received.count == 2 { break }
    }
    await socket.didSend.wait(for: 1)

    #expect(received.map(\.0) == ["héllo", "\u{1B}cscreen"])
    #expect(received.map(\.1) == [false, true])
    #expect(transport.roundTripTime != nil)
    let ping = try #require(socket.sentFrames.first { $0["type"] as? String == "ping" })
    #expect(ping["t"] is Double)
    transport.detach()
  }

  @Test("Hide and clear go to protocol 2 servers; older ones get Ctrl-L", .timeLimit(.minutes(1)))
  func hideAndClear() async throws {
    let modern = ProtocolSocket(messages: [.string(#"{"type":"ready","seq":0,"protocol":2}"#)])
    let transport = TerminalTransport(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: FreshTerminal(),
        webSocketTransport: OneSocket(socket: modern)
      ),
      sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
      onEvent: { _ in }
    )
    transport.sendResize(cols: 80, rows: 24)
    try await transport.open(sessionId: "s", cwd: "/", cols: 80, rows: 24)
    await modern.didSend.wait(for: 2)
    transport.sendHidden()
    transport.sendClear()
    transport.reassertSize()
    await modern.didSend.wait(for: 5)
    let types = modern.sentFrames.compactMap { $0["type"] as? String }.filter { $0 != "ping" }
    #expect(types == ["resize", "hide", "clear", "resize"])
    transport.detach()

    let legacy = ProtocolSocket(messages: [])
    let old = TerminalTransport(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: FreshTerminal(),
        webSocketTransport: OneSocket(socket: legacy)
      ),
      onEvent: { _ in }
    )
    try await old.open(sessionId: "s", cwd: "/", cols: 80, rows: 24)
    old.sendHidden()
    old.sendClear()
    await legacy.didSend.wait(for: 1)
    #expect(legacy.sentFrames.map { $0["type"] as? String } == ["input"])
    #expect(legacy.sentFrames.first?["data"] as? String == "\u{0C}")
    old.detach()
  }

  @Test("Frames a dying socket swallowed are sent again after the reconnect", .timeLimit(.minutes(1)))
  func resendsUnacknowledgedFrames() async throws {
    let first = ProtocolSocket(messages: [
      .string(#"{"type":"ready","seq":0,"protocol":2}"#),
      .string(#"{"type":"ack","seq":0,"clientSeq":1}"#),
      .string(#"{"type":"size","seq":0,"cols":80,"rows":24}"#),
    ])
    let second = ProtocolSocket(messages: [.string(#"{"type":"ready","seq":0,"protocol":2}"#)])
    let sockets = SocketSequence([first, second])
    let clock = TestClock()
    let acknowledged = TestSignal()
    let transport = TerminalTransport(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: FreshTerminal(),
        webSocketTransport: sockets
      ),
      sleep: { duration in
        if duration >= .seconds(5) { try await clock.sleep(for: duration) }
      },
      onEvent: { event in
        if case .ptySize = event { acknowledged.signal() }
      }
    )
    transport.sendResize(cols: 80, rows: 24)
    try await transport.open(sessionId: "s", cwd: "/", cols: 80, rows: 24)
    await acknowledged.wait()
    await first.didSend.wait(for: 2)
    transport.sendInput("ls")
    await first.didSend.wait(for: 3)
    first.cancel(with: .abnormalClosure, reason: nil)
    await sockets.didConnect.wait(for: 2)
    await second.didSend.wait(for: 3)

    let resent = second.sentFrames.filter { $0["type"] as? String != "ping" }
    #expect(resent.first?["type"] as? String == "input")
    #expect(resent.first?["data"] as? String == "ls")
    #expect(resent.first?["clientSeq"] as? Int == 2)
    #expect(resent.dropFirst().first?["type"] as? String == "resize")
    #expect(resent.dropFirst().first?["clientSeq"] as? Int == 3)
    transport.detach()
  }

  @Test("A claim waits for protocol 2 and is made again after a reconnect", .timeLimit(.minutes(1)))
  func claimSurvivesReconnect() async throws {
    let first = ProtocolSocket(messages: [.string(#"{"type":"ready","seq":0,"protocol":2}"#)])
    let second = ProtocolSocket(messages: [.string(#"{"type":"ready","seq":0,"protocol":2}"#)])
    let sockets = SocketSequence([first, second])
    let timing = ReconnectTiming(pingInterval: TerminalTransport.pingInterval)
    let transport = TerminalTransport(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: FreshTerminal(),
        webSocketTransport: sockets
      ),
      sleep: { try await timing.sleep(for: $0) },
      onEvent: { _ in }
    )
    defer { transport.detach(); timing.releaseReconnect.signal() }
    transport.sendResize(cols: 80, rows: 24)
    transport.sendFocus()
    try await transport.open(sessionId: "s", cwd: "/", cols: 80, rows: 24)
    await first.didSend.wait(for: 3)
    #expect(first.sentFrames.compactMap { $0["type"] as? String }.filter { $0 != "ping" } == ["resize", "focus"])
    await timing.clock.waitForSleep(timing.pingInterval)
    first.cancel(with: .abnormalClosure, reason: nil)
    await timing.reconnectWaiting.wait()
    #expect(sockets.didConnect.value == 1)
    timing.releaseReconnect.signal()
    await sockets.didConnect.wait(for: 2)
    await timing.clock.waitForSleep(timing.pingInterval, count: 2)
    await second.didSend.wait(for: 5)
    let types = second.sentFrames.compactMap { $0["type"] as? String }.filter { $0 != "ping" }
    #expect(types == ["resize", "focus", "resize", "focus"])
  }

  @Test("Another client's size after the claim ends it", .timeLimit(.minutes(1)))
  func claimEndsWhenAnotherClientTakesTheSize() async throws {
    let first = ProtocolSocket(messages: [
      .string(#"{"type":"ready","seq":0,"protocol":2}"#),
      .string(#"{"type":"size","seq":0,"cols":120,"rows":40}"#),
      .string(#"{"type":"ack","seq":0,"clientSeq":2}"#),
      .string(#"{"type":"size","seq":0,"cols":200,"rows":50}"#),
    ])
    let second = ProtocolSocket(messages: [.string(#"{"type":"ready","seq":0,"protocol":2}"#)])
    let sockets = SocketSequence([first, second])
    let timing = ReconnectTiming(pingInterval: TerminalTransport.pingInterval)
    let sizes = TestSignal()
    let transport = TerminalTransport(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: FreshTerminal(),
        webSocketTransport: sockets
      ),
      sleep: { try await timing.sleep(for: $0) },
      onEvent: { event in
        if case .ptySize = event { sizes.signal() }
      }
    )
    defer { transport.detach(); timing.releaseReconnect.signal() }
    transport.sendResize(cols: 80, rows: 24)
    transport.sendFocus()
    try await transport.open(sessionId: "s", cwd: "/", cols: 80, rows: 24)
    await sizes.wait(for: 2)
    await timing.clock.waitForSleep(timing.pingInterval)
    first.cancel(with: .abnormalClosure, reason: nil)
    await timing.reconnectWaiting.wait()
    #expect(sockets.didConnect.value == 1)
    timing.releaseReconnect.signal()
    await sockets.didConnect.wait(for: 2)
    await timing.clock.waitForSleep(timing.pingInterval, count: 2)
    await second.didSend.wait(for: 2)
    transport.sendClear()
    await second.didSend.wait(for: 3)
    let types = second.sentFrames.compactMap { $0["type"] as? String }.filter { $0 != "ping" }
    #expect(types == ["resize", "clear"])
  }
}

import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

private final class StreamSocket: ServerWebSocketConnecting, @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [ServerWebSocketMessage]
  private var waiter: CheckedContinuation<ServerWebSocketMessage, Error>?
  private var closed = false
  private var sent: [String] = []
  let didSend = TestSignal()

  init(messages: [ServerWebSocketMessage]) { pending = messages }

  var closeCode: URLSessionWebSocketTask.CloseCode { lock.withLock { closed ? .goingAway : .invalid } }
  var inputFrames: [[String: Any]] {
    lock.withLock { sent }.compactMap {
      guard let object = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any],
        object["type"] as? String == "input"
      else { return nil }
      return object
    }
  }
  var inputs: [String] {
    lock.withLock { sent }.compactMap {
      guard let object = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any],
        object["type"] as? String == "input"
      else { return nil }
      return object["data"] as? String
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

  /// Delivers a server message now (after the scripted ones).
  func deliver(_ message: ServerWebSocketMessage) {
    let waiting: CheckedContinuation<ServerWebSocketMessage, Error>? = lock.withLock {
      if let waiter {
        self.waiter = nil
        return waiter
      }
      pending.append(message)
      return nil
    }
    waiting?.resume(returning: message)
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    lock.withLock {
      closed = true
      waiter?.resume(throwing: CancellationError())
      waiter = nil
    }
  }
}

private struct SocketTransport: ServerWebSocketTransport {
  let socket: StreamSocket
  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting { socket }
}

private struct Terminal: ServerRequestTransport {
  let head: Int
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let body = Data(#"{"terminalId":"t","websocketPath":"/v1/terminals/t/ws","nextOutputSeq":\#(head)}"#.utf8)
    let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
    return (body, response)
  }
}

private struct Unreachable: ServerRequestTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw URLError(.cannotConnectToHost)
  }
}

@MainActor
private final class RecordingRenderer: TerminalRenderer {
  var writes: [(String, Bool)] = []
  var exits: [Int?] = []
  var predictions: [EchoPredictor.Overlay?] = []
  let didExit = TestSignal()
  let didWrite = TestSignal()
  func showPrediction(_ overlay: EchoPredictor.Overlay?) { predictions.append(overlay) }
  func writeLive(_ bytes: [UInt8]) {
    writes.append((String(decoding: bytes, as: UTF8.self), false))
    didWrite.signal()
  }
  func writeReplay(_ bytes: [UInt8]) { writes.append((String(decoding: bytes, as: UTF8.self), true)) }
  func processExited(code: Int?) {
    exits.append(code)
    didExit.signal()
  }
}

/// The controller sits between a Ghostty surface and the server: history
/// must reach the renderer as replay (so old queries aren't answered again),
/// even when it arrives before the view exists.
@MainActor
@Suite("Terminal controller")
struct TerminalControllerTests {
  @Test("Output before the renderer attaches is held, then delivered in order", .timeLimit(.minutes(1)))
  func holdsOutputUntilAttached() async throws {
    let socket = StreamSocket(messages: [
      .string(#"{"type":"output","seq":1,"data":"history"}"#),
      .string(#"{"type":"output","seq":2,"data":"live"}"#),
      .string(#"{"type":"exit","seq":3,"exitCode":7}"#),
    ])
    let controller = TerminalController(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: Terminal(head: 2),
        webSocketTransport: SocketTransport(socket: socket)
      ),
      terminalKey: "s", cwd: "/")
    let exited = TestSignal()
    controller.onExit = { exited.signal() }
    controller.start(cols: 80, rows: 24)
    controller.start(cols: 100, rows: 30)
    await exited.wait()

    let renderer = RecordingRenderer()
    controller.attach(renderer)
    #expect(renderer.writes.map(\.0) == ["history", "live"])
    #expect(renderer.writes.map(\.1) == [true, false])
    #expect(renderer.exits == [7])
    #expect(controller.hasExited && controller.exitCode == 7)
    // An exited terminal takes no more input, clears, or visibility changes.
    controller.input(Array("ignored".utf8))
    controller.clear()
    controller.setVisible(false)
    controller.reconnect()
    controller.detach()
  }

  @Test("Input and sizes flow to the server; failures are reported", .timeLimit(.minutes(1)))
  func forwardsInput() async throws {
    let socket = StreamSocket(messages: [])
    let controller = TerminalController(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: Terminal(head: 1),
        webSocketTransport: SocketTransport(socket: socket)
      ),
      terminalKey: "s", cwd: "/")
    let renderer = RecordingRenderer()
    controller.attach(renderer)
    controller.start(cols: 80, rows: 24)
    controller.input(Array("ls\r".utf8))
    controller.input([])
    controller.resize(cols: 0, rows: 24)
    controller.resize(cols: 90, rows: 24)
    // Typed before the socket existed: queued input, then the latest size.
    await socket.didSend.wait(for: 2)
    #expect(socket.inputs == ["ls\r"])
    #expect(controller.roundTripTime == nil)
    controller.setVisible(false)
    controller.setVisible(true)
    controller.clear()
    controller.reconnect()
    controller.close()

    let failing = TerminalController(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: Unreachable(),
        webSocketTransport: SocketTransport(socket: StreamSocket(messages: []))
      ),
      terminalKey: "s", cwd: "/")
    let reported = TestSignal()
    failing.onError = { _ in reported.signal() }
    failing.start(cols: 80, rows: 24)
    await reported.wait()
    #expect(failing.lastError != nil)
  }

  @Test("Only the client whose size the PTY has answers queries, and answers don't claim it", .timeLimit(.minutes(1)))
  func queryRepliesDontClaimTheSize() async throws {
    let socket = StreamSocket(messages: [
      .string(#"{"type":"ready","seq":0,"protocol":2}"#),
      // Another client is being used, at its own size.
      .string(#"{"type":"size","seq":0,"cols":120,"rows":40}"#),
    ])
    let now = LockedInstant(ContinuousClock.now)
    let controller = TerminalController(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: Terminal(head: 0),
        webSocketTransport: SocketTransport(socket: socket)
      ),
      terminalKey: "s", cwd: "/", clock: { now.value })
    let sized = TestSignal()
    controller.onPTYSize = { _, _ in sized.signal() }
    #expect(controller.answersQueries)
    controller.start(cols: 80, rows: 24)
    await sized.wait()
    // Watching: this client's terminal doesn't answer the program.
    #expect(!controller.answersQueries)
    controller.produced(Array("\u{1B}[?62c".utf8))
    // Typed here: this client is being used.
    controller.noteUserInput()
    controller.produced(Array("x".utf8))
    #expect(controller.claimsSize && controller.answersQueries)
    // Later, its replies go to the program without claiming anything.
    now.advance(by: .seconds(1))
    controller.produced(Array("\u{1B}[?62c".utf8))
    // resize, ping, "x", the reply.
    await socket.didSend.wait(for: 4)
    #expect(socket.inputs == ["x", "\u{1B}[?62c"])
    #expect(socket.inputFrames.map { $0["claim"] as? Bool } == [nil, false])
    controller.detach()
  }

  @Test("On a slow link, typed text shows at once and clears when echoed", .timeLimit(.minutes(1)))
  func predictsEchoOnSlowLinks() async throws {
    let socket = StreamSocket(messages: [
      .string(#"{"type":"ready","seq":0,"protocol":2}"#),
      // A pong for a ping "sent" half a second ago: a slow link.
      .string(#"{"type":"pong","seq":0,"t":-500}"#),
      .string(#"{"type":"size","seq":0,"cols":120,"rows":40}"#),
      .string(#"{"type":"output","seq":1,"data":"$ "}"#),
    ])
    let controller = TerminalController(
      config: CodevisorServerConfig(
        baseURL: URL(string: "https://fixture.invalid")!,
        requestTransport: Terminal(head: 1),
        webSocketTransport: SocketTransport(socket: socket)
      ),
      terminalKey: "s", cwd: "/",
      sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    let renderer = RecordingRenderer()
    controller.attach(renderer)
    var announced: [Int] = []
    controller.onPTYSize = { cols, rows in announced = [cols, rows] }
    controller.start(cols: 80, rows: 24)
    await renderer.didWrite.wait(for: 1)
    #expect(controller.roundTripTime.map { $0 > .milliseconds(30) } == true)
    // The PTY's size, as the server announced it.
    #expect(controller.ptySize.map { [$0.cols, $0.rows] } == [120, 40])
    #expect(announced == [120, 40])

    controller.input(Array("l".utf8))
    #expect(renderer.predictions == [.init(text: "l", underlined: false)])
    socket.deliver(.string(#"{"type":"output","seq":2,"data":"l"}"#))
    await renderer.didWrite.wait(for: 2)
    #expect(renderer.predictions.last == .some(nil))
    controller.detach()
  }
}

private final class LockedInstant: @unchecked Sendable {
  private let lock = NSLock()
  private var instant: ContinuousClock.Instant
  init(_ instant: ContinuousClock.Instant) { self.instant = instant }
  var value: ContinuousClock.Instant { lock.withLock { instant } }
  func advance(by duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

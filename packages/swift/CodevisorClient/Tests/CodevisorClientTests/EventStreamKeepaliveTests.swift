import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorClient

private final class ScriptedEventSocket: ServerWebSocketConnecting, @unchecked Sendable {
  let receiving = TestSignal()
  private let lock = NSLock()
  private var calls: [String] = []
  private let stream: AsyncThrowingStream<ServerWebSocketMessage, any Error>
  private let continuation: AsyncThrowingStream<ServerWebSocketMessage, any Error>.Continuation
  private var iterator: AsyncThrowingStream<ServerWebSocketMessage, any Error>.Iterator

  init() {
    (stream, continuation) = AsyncThrowingStream.makeStream()
    iterator = stream.makeAsyncIterator()
  }

  func push(_ json: String) {
    continuation.yield(.string(json))
  }

  func fail() {
    continuation.finish(throwing: URLError(.networkConnectionLost))
  }

  func send(_ message: ServerWebSocketMessage) async throws {}

  func receive() async throws -> ServerWebSocketMessage {
    receiving.signal()
    guard let next = try await iterator.next() else {
      throw URLError(.networkConnectionLost)
    }
    return next
  }

  var lifecycle: [String] { lock.withLock { calls } }

  func markUnanswered() {
    lock.withLock { calls.append("unanswered") }
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    lock.withLock { calls.append("cancel") }
    continuation.finish(throwing: URLError(.cancelled))
  }

  var closeCode: URLSessionWebSocketTask.CloseCode { .invalid }
}

private final class ScriptedEventTransport: ServerWebSocketTransport, @unchecked Sendable {
  private let lock = NSLock()
  let connected = TestSignal()
  private var connections: [(request: URLRequest, socket: ScriptedEventSocket, maximumMessageSize: Int)] = []

  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
    let socket = ScriptedEventSocket()
    lock.withLock { connections.append((request, socket, maximumMessageSize)) }
    connected.signal()
    return socket
  }

  var maximumMessageSizes: [Int] {
    lock.withLock { connections.map(\.maximumMessageSize) }
  }

  var requests: [URLRequest] {
    lock.withLock { connections.map(\.request) }
  }

  func socket(_ index: Int) -> ScriptedEventSocket? {
    lock.withLock { connections.count > index ? connections[index].socket : nil }
  }
}

private func envelope(kind: String, id: Int) -> String {
  """
  {"id":\(id),"serverId":"srv","kind":"\(kind)","subjectId":"subject",\
  "createdAt":"2026-08-18T00:00:00.000Z","payload":{}}
  """
}

private func since(of request: URLRequest?) -> String? {
  guard let url = request?.url,
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
  else { return nil }
  return components.queryItems?.first(where: { $0.name == "since" })?.value
}

@Suite("Event stream keepalives", .timeLimit(.minutes(1)))
struct EventStreamKeepaliveTests {
  private func makeClient(_ transport: ScriptedEventTransport, clock: TestClock = TestClock()) -> CodevisorServerClient
  {
    CodevisorServerClient(
      config: CodevisorServerConfig(
        baseURL: URL(string: "http://127.0.0.1:9")!,
        webSocketTransport: transport
      ),
      eventSleep: { duration in
        if duration == CodevisorServerClient.eventReceiveDeadline || duration == CodevisorServerClient.eventOpenDeadline
        {
          try await clock.sleep(for: duration)
        }
      }
    )
  }

  @Test("Keepalives are swallowed and never move the cursor")
  func keepalivesAreFiltered() async throws {
    let transport = ScriptedEventTransport()
    let client = makeClient(transport)
    let received = LockedBox<[Int]>([])
    let delivered = TestSignal()
    let consumer = Task {
      for try await event in client.sessionEventStream(id: UUID(), since: 0) {
        guard event.kind != "client.synchronization" else { continue }
        received.mutate { $0.append(event.id) }
        delivered.signal()
      }
    }
    await transport.connected.wait()
    let first = transport.socket(0)!
    first.push(envelope(kind: "keepalive", id: 0))
    first.push(envelope(kind: "session.output", id: 7))
    first.push(envelope(kind: "keepalive", id: 7))
    await delivered.wait()

    first.fail()
    await transport.connected.wait(for: 2)
    #expect(since(of: transport.requests.last) == "7")
    #expect(received.value == [7])
    consumer.cancel()
    _ = await consumer.result
  }

  @Test("Event sockets accept multi-megabyte tool results")
  func eventSocketMessageLimit() async throws {
    let transport = ScriptedEventTransport()
    let client = makeClient(transport)
    let consumer = Task {
      for try await _ in client.sessionEventStream(id: UUID(), since: 0) {}
    }
    await transport.connected.wait()
    #expect(transport.maximumMessageSizes == [16 * 1024 * 1024])
    consumer.cancel()
    _ = await consumer.result
  }

  @Test("A keepalive never collapses a live-only sentinel cursor")
  func keepaliveKeepsSentinel() async throws {
    let transport = ScriptedEventTransport()
    let client = makeClient(transport)
    let sentinel = ServerSessionTransport.liveOnlyEventCursor
    let consumer = Task {
      for try await _ in client.sessionEventStream(id: UUID(), since: sentinel) {}
    }
    await transport.connected.wait()
    let first = transport.socket(0)!
    first.push(envelope(kind: "keepalive", id: 0))
    await first.receiving.wait(for: 2)
    first.fail()
    await transport.connected.wait(for: 2)
    #expect(since(of: transport.requests.last) == String(sentinel))
    consumer.cancel()
    _ = await consumer.result
  }

  @Test("Silence after a keepalive trips the receive deadline and reconnects")
  func deadlineReconnects() async throws {
    let clock = TestClock()
    let transport = ScriptedEventTransport()
    let client = makeClient(transport, clock: clock)
    let consumer = Task {
      for try await _ in client.sessionEventStream(id: UUID(), since: 3) {}
    }
    await transport.connected.wait()
    transport.socket(0)!.push(envelope(kind: "keepalive", id: 3))
    await clock.waitForSleep(.seconds(90))
    clock.advance(by: .seconds(90))
    await transport.connected.wait(for: 2)
    #expect(since(of: transport.requests.last) == "3")

    await clock.waitForSleep(CodevisorServerClient.eventOpenDeadline)
    clock.advance(by: CodevisorServerClient.eventOpenDeadline)
    await transport.connected.wait(for: 3)
    #expect(since(of: transport.requests.last) == "3")
    consumer.cancel()
    _ = await consumer.result
  }
  @Test("A socket that never delivers its first frame reconnects and reports recovery")
  func firstFrameDeadline() async {
    let clock = TestClock()
    let transport = ScriptedEventTransport()
    let client = makeClient(transport, clock: clock)
    let recovering = TestSignal()
    let consumer = Task {
      for try await event in client.sessionEventStream(id: UUID(), since: 12) {
        if event.payload["state"]?.stringValue == "reconnecting" { recovering.signal() }
      }
    }
    await transport.connected.wait()
    await clock.waitForSleep(CodevisorServerClient.eventOpenDeadline)
    clock.advance(by: CodevisorServerClient.eventOpenDeadline)
    await recovering.wait()
    await transport.connected.wait(for: 2)
    #expect(since(of: transport.requests.last) == "12")
    #expect(transport.socket(0)?.lifecycle.prefix(2) == ["unanswered", "cancel"])
    consumer.cancel()
    _ = await consumer.result
  }

  @Test("A revision gap ends the stream before later content is applied")
  func revisionGapRequiresSnapshot() async {
    let transport = ScriptedEventTransport()
    let client = makeClient(transport)
    let consumer = Task { () throws -> [Int] in
      var ids: [Int] = []
      for try await event in client.sessionEventStream(id: UUID(), since: 3) {
        #expect(event.payload["state"]?.stringValue != "catchingUp")
        if event.kind != "client.synchronization" { ids.append(event.id) }
      }
      return ids
    }
    await transport.connected.wait()
    let gap = envelope(kind: "session.output", id: 5).replacingOccurrences(
      of: "\"payload\":{}", with: "\"subjectRevision\":5,\"payload\":{}")
    transport.socket(0)!.push(gap)
    switch await consumer.result {
    case .success: Issue.record("Gap was silently skipped")
    case let .failure(error):
      let gap = error as? CodevisorServerClient.EventStreamGapError
      #expect(gap?.expected == 4)
      #expect(gap?.received == 5)
    }
    #expect(transport.requests.count == 1)
  }

}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ initial: Value) {
    stored = initial
  }

  var value: Value {
    lock.withLock { stored }
  }

  func mutate(_ transform: (inout Value) -> Void) {
    lock.withLock { transform(&stored) }
  }
}

extension EventStreamKeepaliveTests {
  @Test("Shell streams reconnect after silence before or after their first frame", arguments: [false, true])
  func shellDeadlineReconnects(afterFrame: Bool) async throws {
    let clock = TestClock()
    let transport = ScriptedEventTransport()
    let client = makeClient(transport, clock: clock)
    let received = LockedBox<[Int]>([])
    let delivered = TestSignal()
    let consumer = Task {
      for try await event in client.shellEventStream(since: 3, handledKinds: ["session.attention.updated"]) {
        received.mutate { $0.append(event.id) }
        delivered.signal()
      }
    }
    defer { consumer.cancel() }
    await transport.connected.wait()
    #expect(transport.requests.first?.url?.query?.contains("sync=1") == true)
    if afterFrame {
      transport.socket(0)!.push(envelope(kind: "keepalive", id: 3))
    }
    let deadline = afterFrame ? CodevisorServerClient.eventReceiveDeadline : CodevisorServerClient.eventOpenDeadline
    await clock.waitForSleep(deadline)
    clock.advance(by: deadline - .milliseconds(1))
    #expect(transport.requests.count == 1)
    clock.advance(by: .milliseconds(1))
    await transport.connected.wait(for: 2)
    #expect(since(of: transport.requests.last) == "3")
    transport.socket(1)!.push(envelope(kind: "session.attention.updated", id: 4))
    await delivered.wait()
    #expect(received.value == [4])
    consumer.cancel()
    _ = await consumer.result
    #expect(clock.pendingCount == 0)
  }

  @Test("Shell keepalive gaps replay from the last event even with kind filtering", arguments: [false, true])
  func shellCheckpointGap(filtered: Bool) async {
    let transport = ScriptedEventTransport()
    let client = makeClient(transport)
    let delivered = TestSignal()
    let received = LockedBox<[Int]>([])
    let stream =
      filtered
      ? client.shellEventStream(since: 3, handledKinds: ["session.attention.updated"])
      : client.eventStream(since: 3)
    let consumer = Task {
      for try await event in stream {
        received.mutate { $0.append(event.id) }
        delivered.signal()
      }
    }
    defer { consumer.cancel() }
    await transport.connected.wait()
    transport.socket(0)!.push(envelope(kind: "keepalive", id: 4))
    await transport.connected.wait(for: 2)
    #expect(since(of: transport.requests.last) == "3")
    transport.socket(1)!.push(envelope(kind: "session.attention.updated", id: 4))
    await delivered.wait()
    #expect(received.value == [4])
    consumer.cancel()
    _ = await consumer.result
  }

  @Test("Shell predecessor gaps recover before applying later states; filtered events still advance")
  func shellPredecessorGap() async {
    let transport = ScriptedEventTransport()
    let client = makeClient(transport)
    let received = LockedBox<[Int]>([])
    let delivered = TestSignal()
    let consumer = Task {
      for try await event in client.shellEventStream(since: 3, handledKinds: ["session.attention.updated"]) {
        received.mutate { $0.append(event.id) }
        delivered.signal()
      }
    }
    defer { consumer.cancel() }
    await transport.connected.wait()
    func shellEvent(_ id: Int, previous: Int, kind: String = "session.attention.updated") -> String {
      envelope(kind: kind, id: id).replacingOccurrences(
        of: "\"payload\":{}", with: "\"previousEventId\":\(previous),\"payload\":{}")
    }
    transport.socket(0)!.push(shellEvent(5, previous: 4))
    await transport.connected.wait(for: 2)
    #expect(since(of: transport.requests.last) == "3")
    #expect(received.value.isEmpty)
    let socket = transport.socket(1)!
    socket.push(shellEvent(4, previous: 3))
    socket.push(shellEvent(5, previous: 4, kind: "plugin.updated"))
    socket.push(shellEvent(8, previous: 5))
    socket.push(shellEvent(8, previous: 5))
    socket.push(shellEvent(9, previous: 8))
    await delivered.wait(for: 3)
    #expect(received.value == [4, 8, 9])
    socket.fail()
    await transport.connected.wait(for: 3)
    #expect(since(of: transport.requests.last) == "9")
    consumer.cancel()
    _ = await consumer.result
  }

  @Test("Shell heartbeats preserve live-only cursors", arguments: [false, true])
  func shellSentinel(filtered: Bool) async {
    let transport = ScriptedEventTransport()
    let client = makeClient(transport)
    let sentinel = ServerSessionTransport.liveOnlyEventCursor
    let stream =
      filtered
      ? client.shellEventStream(since: sentinel, handledKinds: ["session.attention.updated"])
      : client.eventStream(since: sentinel)
    let consumer = Task { for try await _ in stream {} }
    defer { consumer.cancel() }
    await transport.connected.wait()
    let socket = transport.socket(0)!
    socket.push(envelope(kind: "keepalive", id: 0))
    await socket.receiving.wait(for: 2)
    socket.fail()
    await transport.connected.wait(for: 2)
    #expect(since(of: transport.requests.last) == String(sentinel))
    consumer.cancel()
    _ = await consumer.result
  }

  @Test("Malformed handled shell events request snapshot recovery without advancing past the event")
  func invalidShellEventRequiresSnapshot() async {
    let transport = ScriptedEventTransport()
    let client = makeClient(transport)
    let consumer = Task {
      for try await _ in client.shellEventStream(since: 3, handledKinds: ["session.attention.updated"]) {
        Issue.record("Malformed event was applied")
      }
    }
    defer { consumer.cancel() }
    await transport.connected.wait()
    transport.socket(0)!.push("{\"id\":4,\"kind\":\"session.attention.updated\"}")
    switch await consumer.result {
    case .success: Issue.record("Malformed event was silently skipped")
    case let .failure(error): #expect(error is DecodingError)
    }
    #expect(transport.requests.count == 1)
  }

  @Test("Old-server traffic confirms connection before its first heartbeat", arguments: [false, true])
  func trafficConfirmsConnection(afterFailure: Bool) async {
    let transport = ScriptedEventTransport()
    let client = makeClient(transport)
    let received = LockedBox<[String]>([])
    let delivered = TestSignal()
    let consumer = Task {
      for try await event in client.sessionEventStream(id: UUID(), since: 3) {
        received.mutate { $0.append(event.payload["state"]?.stringValue ?? event.kind) }
        if event.kind == "session.output" { delivered.signal() }
      }
    }
    defer { consumer.cancel() }
    await transport.connected.wait()
    if afterFailure {
      transport.socket(0)!.fail()
      await transport.connected.wait(for: 2)
    }
    let socket = transport.socket(afterFailure ? 1 : 0)!
    socket.push(envelope(kind: "session.output", id: 4))
    await delivered.wait()
    #expect(received.value == (afterFailure ? ["reconnecting"] : []) + ["catchingUp", "session.output"])

    socket.push(envelope(kind: "keepalive", id: 5))
    switch await consumer.result {
    case .success: Issue.record("Missing tail was silently accepted")
    case let .failure(error):
      let gap = error as? CodevisorServerClient.EventStreamGapError
      #expect(gap?.expected == 4)
      #expect(gap?.received == 5)
    }
    #expect(!received.value.contains("caughtUp"))
  }

  @Test("A checkpoint beyond received events cannot declare the transcript caught up")
  func checkpointDetectsMissingTail() async {
    let transport = ScriptedEventTransport()
    let client = makeClient(transport)
    let consumer = Task {
      for try await event in client.sessionEventStream(id: UUID(), since: 3) {
        #expect(event.payload["state"]?.stringValue != "caughtUp")
      }
    }
    await transport.connected.wait()
    transport.socket(0)!.push(envelope(kind: "keepalive", id: 4))
    switch await consumer.result {
    case .success: Issue.record("Missing tail was accepted as caught up")
    case let .failure(error): #expect(error is CodevisorServerClient.EventStreamGapError)
    }
  }
}

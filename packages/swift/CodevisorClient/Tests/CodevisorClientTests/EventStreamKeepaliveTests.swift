import Foundation
import Testing

@testable import CodevisorClient

/// A scripted socket: `receive()` waits on pushed messages and hangs silently
/// when none arrive — exactly like a dead relay channel.
private final class ScriptedEventSocket: ServerWebSocketConnecting, @unchecked Sendable {
  private let stream: AsyncThrowingStream<ServerWebSocketMessage, any Error>
  private let continuation: AsyncThrowingStream<ServerWebSocketMessage, any Error>.Continuation
  // Single-consumer, like a URLSessionWebSocketTask receive loop.
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
    guard let next = try await iterator.next() else {
      throw URLError(.networkConnectionLost)
    }
    return next
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    continuation.finish(throwing: URLError(.cancelled))
  }

  var closeCode: URLSessionWebSocketTask.CloseCode { .invalid }
}

private final class ScriptedEventTransport: ServerWebSocketTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var connections: [(request: URLRequest, socket: ScriptedEventSocket)] = []

  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
    let socket = ScriptedEventSocket()
    lock.withLock { connections.append((request, socket)) }
    return socket
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

private func waitUntil(
  timeout: Duration = .seconds(5),
  _ condition: @Sendable () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

@Suite("Event stream keepalives")
struct EventStreamKeepaliveTests {
  private func makeClient(_ transport: ScriptedEventTransport) -> CodevisorServerClient {
    CodevisorServerClient(
      config: CodevisorServerConfig(
        baseURL: URL(string: "http://127.0.0.1:9")!,
        webSocketTransport: transport
      )
    )
  }

  @Test("Keepalives are swallowed and never move the cursor")
  func keepalivesAreFiltered() async throws {
    let transport = ScriptedEventTransport()
    let client = makeClient(transport)
    let received = LockedBox<[Int]>([])
    let consumer = Task {
      for try await event in client.sessionEventStream(id: UUID(), since: 0) {
        received.mutate { $0.append(event.id) }
      }
    }
    #expect(await waitUntil { transport.requests.count == 1 })
    let first = transport.socket(0)!
    first.push(envelope(kind: "keepalive", id: 0))
    first.push(envelope(kind: "session.output", id: 7))
    first.push(envelope(kind: "keepalive", id: 7))
    #expect(await waitUntil { received.value == [7] })

    // Reconnects resume from the real event's cursor.
    first.fail()
    #expect(await waitUntil { transport.requests.count == 2 })
    #expect(since(of: transport.requests.last) == "7")
    #expect(received.value == [7])
    consumer.cancel()
  }

  @Test("A keepalive never collapses a live-only sentinel cursor")
  func keepaliveKeepsSentinel() async throws {
    let transport = ScriptedEventTransport()
    let client = makeClient(transport)
    let sentinel = ServerSessionTransport.liveOnlyEventCursor
    let consumer = Task {
      for try await _ in client.sessionEventStream(id: UUID(), since: sentinel) {}
    }
    #expect(await waitUntil { transport.requests.count == 1 })
    let first = transport.socket(0)!
    // A keepalive arrives before any real event (its id is the server's
    // zero cursor). Adopting it would turn the next reconnect into a
    // full-history replay.
    first.push(envelope(kind: "keepalive", id: 0))
    try? await Task.sleep(for: .milliseconds(50))
    first.fail()
    #expect(await waitUntil { transport.requests.count == 2 })
    #expect(since(of: transport.requests.last) == String(sentinel))
    consumer.cancel()
  }

  @Test("Silence after a keepalive trips the receive deadline and reconnects")
  func deadlineReconnects() async throws {
    let original = CodevisorServerClient.eventReceiveDeadline
    CodevisorServerClient.eventReceiveDeadline = .milliseconds(80)
    defer { CodevisorServerClient.eventReceiveDeadline = original }

    let transport = ScriptedEventTransport()
    let client = makeClient(transport)
    let consumer = Task {
      for try await _ in client.sessionEventStream(id: UUID(), since: 3) {}
    }
    #expect(await waitUntil { transport.requests.count == 1 })
    // The server proves it sends keepalives, then the path dies silently
    // (orphaned relay channel, half-open TCP): the deadline must fire and
    // re-dial from the cursor.
    transport.socket(0)!.push(envelope(kind: "keepalive", id: 3))
    #expect(await waitUntil { transport.requests.count == 2 })
    #expect(since(of: transport.requests.last) == "3")

    // A keepalive-free socket (old server) keeps unbounded receives: no
    // deadline, no churn.
    try? await Task.sleep(for: .milliseconds(250))
    #expect(transport.requests.count == 2)
    consumer.cancel()
  }
}

/// Minimal thread-safe box for cross-task assertions.
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

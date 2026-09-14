import ACPKit
import CodevisorProtocol
import Foundation

public struct ServerEventEnvelope: Decodable, Equatable, Sendable {
  public var id: Int
  public var globalEventId: Int? = nil
  public var subjectRevision: Int? = nil
  public var serverId: String
  public var kind: String
  public var subjectId: String
  public var createdAt: String
  public var payload: JSONValue

  public init(
    id: Int,
    globalEventId: Int? = nil,
    subjectRevision: Int? = nil,
    serverId: String,
    kind: String,
    subjectId: String,
    createdAt: String,
    payload: JSONValue
  ) {
    self.id = id
    self.globalEventId = globalEventId
    self.subjectRevision = subjectRevision
    self.serverId = serverId
    self.kind = kind
    self.subjectId = subjectId
    self.createdAt = createdAt
    self.payload = payload
  }
}

extension ServerEventEnvelope {
  static func synchronization(_ state: SessionStreamSynchronization, cursor: Int) -> Self {
    Self(
      id: cursor, serverId: "", kind: "client.synchronization", subjectId: "",
      createdAt: "", payload: .object(["state": .string(state.rawValue)]))
  }

  /// Navigation events carry the authoritative session summary as their
  /// payload. Decode that summary directly so a one-session change does not
  /// require refetching and rebuilding the entire navigation snapshot.
  public func sessionRecord() throws -> ServerSession {
    let data = try JSONEncoder().encode(payload)
    return try JSONDecoder().decode(ServerSession.self, from: data)
  }
}

extension CodevisorServerClient {
  private struct ShellEventCursorResponse: Decodable {
    let cursor: Int
  }

  /// Captures the durable global-log tip before navigation snapshots are
  /// fetched. Subscribing from this cursor afterward replays every event that
  /// raced those snapshots without replaying the server's lifetime log.
  public func latestShellEventCursor() async throws -> Int {
    do {
      let response: ShellEventCursorResponse = try await get("/v1/events/cursor")
      return response.cursor
    } catch CodevisorServerClientError.httpStatus(404, _) {
      // Compatibility with older servers: replaying from zero is more
      // expensive, but it is gapless and therefore safe.
      return 0
    }
  }

  public func eventStream(since: Int = 0) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    makeEventStream(path: "/v1/events/socket", since: since)
  }

  public func shellEventStream() -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    // listProjects/listSessions is the snapshot; only events after the
    // socket attaches are needed here.
    makeEventStream(path: "/v1/events/socket", since: ServerSessionTransport.liveOnlyEventCursor)
  }

  public func shellEventStream(handledKinds: Set<String>) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    makeEventStream(
      path: "/v1/events/socket",
      since: ServerSessionTransport.liveOnlyEventCursor,
      handledKinds: handledKinds
    )
  }

  public func shellEventStream(
    since: Int,
    handledKinds: Set<String>
  ) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    makeEventStream(
      path: "/v1/events/socket",
      since: since,
      handledKinds: handledKinds
    )
  }

  public func sessionEventStream(id: UUID, since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    makeEventStream(path: "/v1/sessions/\(id.uuidString)/events/socket", since: since)
  }

  /// Just enough of the envelope to advance the cursor and decide whether
  /// the full payload is worth decoding. `session.output` chunks dominate
  /// the global socket during streaming; skipping their `JSONValue` tree
  /// build here is the difference between O(tokens) and O(handled events).
  private struct ServerEventKindProbe: Decodable {
    var id: Int
    var kind: String
  }

  private func makeEventStream(
    path: String,
    since: Int,
    handledKinds: Set<String>? = nil
  ) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var cursor = since
        var failures = 0
        let scoped = path.hasPrefix("/v1/sessions/")
        while !Task.isCancelled {
          do {
            try await waitForServerIfNeeded(path: path)
            var request = URLRequest(url: try websocketURL(for: "\(path)?since=\(cursor)\(scoped ? "&sync=1" : "")"))
            applyAuthorization(to: &request)
            let socket = webSocketTransport.connect(
              request,
              maximumMessageSize: Self.eventWebSocketMaximumMessageSize
            )
            defer { socket.cancel(with: .goingAway, reason: nil) }

            // Scoped sockets must never wait indefinitely, including
            // when a replay starts but its final checkpoint is lost.
            var expectsKeepalives = false
            var receivedFirstFrame = false
            var needsConnectionConfirmation = scoped
            while !Task.isCancelled {
              let deadline: Duration? =
                !receivedFirstFrame && scoped
                ? Self.eventOpenDeadline : (scoped || expectsKeepalives ? Self.eventReceiveDeadline : nil)
              let message = try await receiveEventMessage(socket, deadline: deadline)
              receivedFirstFrame = true
              guard let data = Self.data(from: message) else { continue }
              if let handledKinds {
                let probe = try decoder.decode(ServerEventKindProbe.self, from: data)
                // Keepalives prove liveness; they are not
                // events. Skip before the cursor advance: a
                // live-only sentinel must never adopt one.
                if probe.kind == Self.keepaliveEventKind {
                  expectsKeepalives = true
                  failures = 0
                  continue
                }
                // Filtered events still advance the cursor so a
                // reconnect never replays the skipped volume.
                cursor = Self.advanceEventCursor(cursor, to: probe.id)
                failures = 0
                guard handledKinds.contains(probe.kind) else { continue }
              }
              let event = try decoder.decode(ServerEventEnvelope.self, from: data)
              if event.kind == Self.keepaliveEventKind {
                expectsKeepalives = true
                failures = 0
                if scoped {
                  if cursor < ServerSessionTransport.liveOnlyEventCursor, event.id != cursor {
                    throw EventStreamGapError(expected: cursor, received: event.id)
                  }
                  needsConnectionConfirmation = false
                  continuation.yield(.synchronization(.caughtUp, cursor: cursor))
                }
                continue
              }
              if scoped, cursor < ServerSessionTransport.liveOnlyEventCursor {
                guard event.id > cursor else { continue }
                if event.subjectRevision != nil, event.id != cursor + 1 {
                  throw EventStreamGapError(expected: cursor + 1, received: event.id)
                }
              }
              // Valid replay/live traffic proves the connection is working,
              // even on older servers whose first heartbeat is 25s away.
              // Keep this distinct from caughtUp: only a checkpoint can
              // certify that the durable tail has arrived without gaps.
              if needsConnectionConfirmation {
                continuation.yield(.synchronization(.catchingUp, cursor: cursor))
                needsConnectionConfirmation = false
              }
              // A live-only sentinel cursor means "no real cursor
              // yet". Once the first event arrives, retain its real
              // cursor so a reconnect can replay anything missed
              // afterward.
              cursor = Self.advanceEventCursor(cursor, to: event.id)
              failures = 0
              continuation.yield(event)
            }
          } catch {
            if Task.isCancelled {
              continuation.finish()
              return
            }
            if scoped {
              continuation.yield(.synchronization(.reconnecting, cursor: cursor))
            }
            if error is EventStreamGapError {
              continuation.finish(throwing: error)
              return
            }
            let failure = error as NSError
            if failure.domain == NSPOSIXErrorDomain,
              failure.code == POSIXErrorCode.EMSGSIZE.rawValue
            {
              continuation.finish(throwing: error)
              return
            }
            failures += 1
            Log.server.error(
              "Event socket \(path, privacy: .public) at cursor \(cursor, privacy: .public) failed (attempt \(failures)); reconnecting: \(String(describing: error), privacy: .public)"
            )
            try? await eventSleep(Self.eventReconnectDelay(failures: failures))
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Liveness frames the server interleaves on session event sockets
  /// (~every 25s). Never yielded and never cursor-advancing — their only
  /// job is to make silence measurable.
  static let keepaliveEventKind = "keepalive"

  /// How long a keepalive-bearing socket may stay silent before the path is
  /// declared dead and the stream reconnects from its cursor. A few
  /// multiples of the server cadence, so ordinary jitter never trips it.
  static let eventReceiveDeadline: Duration = .seconds(90)
  // Older servers send their first heartbeat at 25 seconds instead of an
  // immediate checkpoint. Leave room for that additive compatibility path.
  static let eventOpenDeadline: Duration = .seconds(35)

  struct EventStreamStalledError: Error {}
  struct EventStreamGapError: Error {
    let expected: Int
    let received: Int
  }

  /// Races `operation` against the receive deadline. On timeout the thrown
  /// error unwinds through the reconnect path exactly like a socket failure:
  /// the connection's `defer` cancels the socket (tearing down a relayed
  /// channel with it) and the stream re-dials from its cursor.
  private func receiveEventMessage(
    _ socket: any ServerWebSocketConnecting,
    deadline: Duration?
  ) async throws -> ServerWebSocketMessage {
    try await withTaskCancellationHandler {
      guard let deadline else { return try await socket.receive() }
      return try await withThrowingTaskGroup(of: ServerWebSocketMessage.self) { group in
        group.addTask { try await socket.receive() }
        group.addTask {
          try await self.eventSleep(deadline)
          // Close before joining the receive task: cancellation alone may
          // not release a native receive or a channel still being opened.
          socket.cancel(with: .goingAway, reason: nil)
          throw EventStreamStalledError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
      }
    } onCancel: {
      socket.cancel(with: .goingAway, reason: nil)
    }
  }

  /// Advances the reconnect-replay cursor past a received event id. Cursors
  /// at or above `ServerSessionTransport.liveOnlyEventCursor` are live-only
  /// sentinels, not positions (the server treats any `since` >= JS
  /// `Number.MAX_SAFE_INTEGER` as a live-only subscription) — adopt the
  /// first real event id outright so later reconnects replay missed events
  /// instead of resubscribing live-only forever.
  static func advanceEventCursor(_ cursor: Int, to id: Int) -> Int {
    cursor >= ServerSessionTransport.liveOnlyEventCursor ? id : max(cursor, id)
  }

  private static func eventReconnectDelay(failures: Int) -> Duration {
    let base = min(5_000, 250 * (1 << min(failures, 5)))
    let jitter = Int.random(in: 0...250)
    return .milliseconds(base + jitter)
  }

  private static func data(from message: ServerWebSocketMessage) -> Data? {
    switch message {
    case let .data(data):
      return data
    case let .string(text):
      return text.data(using: .utf8)
    }
  }
}

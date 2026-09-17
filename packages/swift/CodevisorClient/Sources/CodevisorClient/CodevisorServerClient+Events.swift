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
  public var transportByteCount: Int? = nil
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
    let response: ShellEventCursorResponse = try await get("/v1/events/cursor")
    return response.cursor
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
    var previousEventId: Int?
  }

  private func makeEventStream(
    path: String,
    since: Int,
    handledKinds: Set<String>? = nil
  ) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
      @Sendable func emit(_ event: ServerEventEnvelope) throws {
        if case .dropped = continuation.yield(event) { throw EventSnapshotRequiredError() }
      }
      let task = Task {
        var cursor = since
        var failures = 0
        let scoped = path.hasPrefix("/v1/sessions/")
        while !Task.isCancelled {
          do {
            try await waitForServerIfNeeded(path: path)
            var request = URLRequest(url: try websocketURL(for: "\(path)?since=\(cursor)&sync=1"))
            applyAuthorization(to: &request)
            let socket = webSocketTransport.connect(
              request,
              maximumMessageSize: Self.eventWebSocketMaximumMessageSize
            )
            defer { socket.cancel(with: .goingAway, reason: nil) }

            // Both shell and chat streams must recover from a half-open
            // path, including one that never delivers its first frame.
            // Older servers ignore sync=1; quiet ones safely reconnect
            // from the same cursor even if they do not send heartbeats.
            var receivedFirstFrame = false
            var needsConnectionConfirmation = scoped
            while !Task.isCancelled {
              let deadline = receivedFirstFrame ? Self.eventReceiveDeadline : Self.eventOpenDeadline
              let message = try await receiveEventMessage(socket, deadline: deadline)
              receivedFirstFrame = true
              guard let data = Self.data(from: message) else { continue }
              // Chat streams need every payload. Decode them only once;
              // the small shell probe avoids building discarded payloads.
              let decodedEvent = scoped ? try decoder.decode(ServerEventEnvelope.self, from: data) : nil
              let probe: ServerEventKindProbe
              if let decodedEvent {
                probe = ServerEventKindProbe(id: decodedEvent.id, kind: decodedEvent.kind)
              } else {
                probe = try decoder.decode(ServerEventKindProbe.self, from: data)
              }
              if probe.kind == "snapshot_required" {
                throw EventSnapshotRequiredError()
              }
              if probe.kind == Self.keepaliveEventKind {
                // Check even filtered shell streams. A heartbeat beyond
                // our received tail is a missed update, not proof of sync.
                if cursor < ServerSessionTransport.liveOnlyEventCursor, probe.id != cursor {
                  throw EventStreamGapError(expected: cursor, received: probe.id)
                }
                failures = 0
                if scoped {
                  needsConnectionConfirmation = false
                  try emit(.synchronization(.caughtUp, cursor: cursor))
                }
                continue
              }
              if cursor < ServerSessionTransport.liveOnlyEventCursor {
                guard probe.id > cursor else { continue }
                // Shell ids may have legitimate holes after migrations.
                // The server links deliveries to their predecessor so a
                // missing frame is detected without assuming id + 1.
                if let previous = probe.previousEventId, previous != cursor {
                  throw EventStreamGapError(expected: cursor, received: previous)
                }
              }
              if let handledKinds, !handledKinds.contains(probe.kind) {
                cursor = Self.advanceEventCursor(cursor, to: probe.id)
                failures = 0
                continue
              }
              var event = try decodedEvent ?? decoder.decode(ServerEventEnvelope.self, from: data)
              event.transportByteCount = data.count
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
                try emit(.synchronization(.catchingUp, cursor: cursor))
                needsConnectionConfirmation = false
              }
              // A live-only sentinel cursor means "no real cursor
              // yet". Once the first event arrives, retain its real
              // cursor so a reconnect can replay anything missed
              // afterward.
              cursor = Self.advanceEventCursor(cursor, to: event.id)
              failures = 0
              try emit(event)
            }
          } catch {
            if Task.isCancelled {
              continuation.finish()
              return
            }
            if scoped {
              try? emit(.synchronization(.reconnecting, cursor: cursor))
            }
            // A shell gap can replay from the unchanged cursor, preserving
            // live attention edges. Invalid envelopes need the machine's
            // authoritative snapshot recovery rather than endless replay.
            if error is EventSnapshotRequiredError || (scoped && error is EventStreamGapError)
              || (!scoped && error is DecodingError)
            {
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

  /// Liveness frames the server interleaves on shell and session sockets
  /// (~every 25s). Never yielded or cursor-advancing; they prove liveness
  /// and check that the delivered tail matches the client's cursor.
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
    deadline: Duration
  ) async throws -> ServerWebSocketMessage {
    try await withTaskCancellationHandler {
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

private struct EventSnapshotRequiredError: Error {}

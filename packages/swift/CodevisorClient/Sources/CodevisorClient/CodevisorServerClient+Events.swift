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

  public func sessionRecord() throws -> ServerSession {
    let data = try JSONEncoder().encode(payload)
    return try JSONDecoder().decode(ServerSession.self, from: data)
  }
}

extension CodevisorServerClient {
  private struct ShellEventCursorResponse: Decodable {
    let cursor: Int
  }

  public func latestShellEventCursor() async throws -> Int {
    let response: ShellEventCursorResponse = try await get("/v1/events/cursor")
    return response.cursor
  }

  public func eventStream(since: Int = 0) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    makeEventStream(path: "/v1/events/socket", since: since)
  }

  public func shellEventStream() -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
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

            var receivedFirstFrame = false
            var needsConnectionConfirmation = scoped
            while !Task.isCancelled {
              let deadline = receivedFirstFrame ? Self.eventReceiveDeadline : Self.eventOpenDeadline
              let message = try await receiveEventMessage(socket, deadline: deadline)
              receivedFirstFrame = true
              guard let data = Self.data(from: message) else { continue }
              let decodedEvent: ServerEventEnvelope?
              if scoped {
                decodedEvent = try decoder.decode(ServerEventEnvelope.self, from: data)
              } else {
                decodedEvent = nil
              }
              let probe = try eventKindProbe(from: data, decodedEvent: decodedEvent)
              if probe.kind == "snapshot_required" {
                throw EventSnapshotRequiredError()
              }
              if probe.kind == Self.keepaliveEventKind {
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
              if needsConnectionConfirmation {
                try emit(.synchronization(.catchingUp, cursor: cursor))
                needsConnectionConfirmation = false
              }
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
            if Self.isTerminalEventFailure(error, scoped: scoped) {
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

  private func eventKindProbe(
    from data: Data,
    decodedEvent: ServerEventEnvelope?
  ) throws -> ServerEventKindProbe {
    if let decodedEvent {
      return ServerEventKindProbe(id: decodedEvent.id, kind: decodedEvent.kind)
    }
    return try decoder.decode(ServerEventKindProbe.self, from: data)
  }

  private static func isTerminalEventFailure(_ error: any Error, scoped: Bool) -> Bool {
    if error is EventSnapshotRequiredError || (scoped && error is EventStreamGapError)
      || (!scoped && error is DecodingError)
    {
      return true
    }
    let failure = error as NSError
    return failure.domain == NSPOSIXErrorDomain
      && failure.code == POSIXErrorCode.EMSGSIZE.rawValue
  }

  static let keepaliveEventKind = "keepalive"

  static let eventReceiveDeadline: Duration = .seconds(90)
  static let eventOpenDeadline: Duration = .seconds(35)

  struct EventStreamStalledError: Error {}
  struct EventStreamGapError: Error {
    let expected: Int
    let received: Int
  }

  private func receiveEventMessage(
    _ socket: any ServerWebSocketConnecting,
    deadline: Duration
  ) async throws -> ServerWebSocketMessage {
    try await withTaskCancellationHandler {
      return try await withThrowingTaskGroup(of: ServerWebSocketMessage.self) { group in
        group.addTask { try await socket.receive() }
        group.addTask {
          try await self.eventSleep(deadline)
          socket.markUnanswered()
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

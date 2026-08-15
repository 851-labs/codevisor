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
    /// Navigation events carry the authoritative session summary as their
    /// payload. Decode that summary directly so a one-session change does not
    /// require refetching and rebuilding the entire navigation snapshot.
    public func sessionRecord() throws -> ServerSession {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(ServerSession.self, from: data)
    }
}

extension CodevisorServerClient {
    public func eventStream(since: Int = 0) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        makeEventStream(path: "/v1/events/socket", since: since)
    }

    public func shellEventStream() -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        // listProjects/listSessions is the snapshot; only events after the
        // socket attaches are needed here.
        makeEventStream(path: "/v1/events/socket", since: Int.max)
    }

    public func shellEventStream(handledKinds: Set<String>) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        makeEventStream(path: "/v1/events/socket", since: Int.max, handledKinds: handledKinds)
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
                while !Task.isCancelled {
                    do {
                        try await waitForServerIfNeeded(path: path)
                        var request = URLRequest(url: try websocketURL(for: "\(path)?since=\(cursor)"))
                        applyAuthorization(to: &request)
                        let socket = webSocketTransport.connect(
                            request,
                            maximumMessageSize: Self.eventWebSocketMaximumMessageSize
                        )
                        defer { socket.cancel(with: .goingAway, reason: nil) }

                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            guard let data = Self.data(from: message) else { continue }
                            if let handledKinds {
                                let probe = try decoder.decode(ServerEventKindProbe.self, from: data)
                                // Filtered events still advance the cursor so a
                                // reconnect never replays the skipped volume.
                                cursor = cursor == Int.max ? probe.id : max(cursor, probe.id)
                                failures = 0
                                guard handledKinds.contains(probe.kind) else { continue }
                            }
                            let event = try decoder.decode(ServerEventEnvelope.self, from: data)
                            // Int.max requests a live-only subscription. Once the
                            // first event arrives, retain its real cursor so a
                            // reconnect can replay anything missed afterward.
                            cursor = cursor == Int.max ? event.id : max(cursor, event.id)
                            failures = 0
                            continuation.yield(event)
                        }
                    } catch {
                        if Task.isCancelled {
                            continuation.finish()
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
                            "Event socket connection failed (consecutive failures: \(failures)); reconnecting: \(String(describing: error), privacy: .public)"
                        )
                        try? await Task.sleep(for: Self.eventReconnectDelay(failures: failures))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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

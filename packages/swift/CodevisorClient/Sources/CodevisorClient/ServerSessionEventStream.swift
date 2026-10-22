import Foundation

struct ServerSessionEventStream: Sendable {
  typealias Envelopes = AsyncThrowingStream<ServerSessionStreamEnvelope, any Error>

  let transport: ServerSessionTransport

  static func droppingCursors(_ envelopes: Envelopes) -> AsyncThrowingStream<ServerSessionStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await envelope in envelopes {
            continuation.yield(envelope.event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func envelopes(since: Int) -> Envelopes {
    AsyncThrowingStream(bufferingPolicy: .bufferingOldest(512)) { continuation in
      let upstream = transport.client.sessionEventStream(id: transport.sessionId, since: since)
      let content = ServerTranscriptContent(transport: transport)
      let task = Task {
        do {
          for try await event in upstream {
            let complete = try await Self.completed(event, content: content)
            try Self.yield(Self.envelopes(for: complete), to: continuation)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func legacyEnvelopes(since: Int) -> Envelopes {
    AsyncThrowingStream { continuation in
      let upstream = transport.client.eventStream(since: since)
      let sessionId = transport.sessionId
      let task = Task {
        do {
          for try await event in upstream where Self.isEvent(event, of: sessionId) {
            for update in ServerSessionEventDecoder.decode(from: event) {
              continuation.yield(ServerSessionStreamEnvelope(cursor: event.id, event: update))
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func completed(
    _ event: ServerEventEnvelope, content: ServerTranscriptContent
  ) async throws -> ServerEventEnvelope {
    var complete = event
    complete.payload = try await content.payload(event.payload)
    return complete
  }

  private static func envelopes(for event: ServerEventEnvelope) -> [ServerSessionStreamEnvelope] {
    updates(in: event).map { update in
      var envelope = ServerSessionStreamEnvelope(cursor: event.id, event: update)
      envelope.byteCount = event.transportByteCount ?? 1024
      return envelope
    }
  }

  private static func updates(in event: ServerEventEnvelope) -> [ServerSessionStreamEvent] {
    let updates = ServerSessionEventDecoder.decode(from: event)
    return updates.isEmpty ? [.synchronization(.cursor)] : updates
  }

  private static func yield(
    _ envelopes: [ServerSessionStreamEnvelope], to continuation: Envelopes.Continuation
  ) throws {
    for envelope in envelopes {
      if case .dropped = continuation.yield(envelope) {
        throw CodevisorServerClientError.invalidResponse
      }
    }
  }

  private static func isEvent(_ event: ServerEventEnvelope, of sessionId: UUID) -> Bool {
    event.subjectId.caseInsensitiveCompare(sessionId.uuidString) == .orderedSame
  }
}

import ACPKit
import Synchronization

/// A buffered stream event plus the server cursor that delivered it. The
/// cursor is nil only for events injected without an envelope (tests and
/// synthetic local events); such events never advance the resume cursor.
struct SessionPendingStreamEvent: Equatable, Sendable {
  var event: ServerSessionStreamEvent
  var cursor: Int?

  init(_ event: ServerSessionStreamEvent, cursor: Int? = nil) {
    self.event = event
    self.cursor = cursor
  }
}

/// Thread-safe ingress for the live ACP stream.
///
/// The socket consumer writes here without entering the main actor. Only the
/// transition from empty to non-empty schedules UI work, so a burst containing
/// hundreds of token events costs one main-actor wakeup before the next
/// presentation frame.
final class SessionEventBuffer: Sendable {
  private struct State: Sendable {
    var events: [SessionPendingStreamEvent] = []
    var generation: UInt64 = 0
    var acceptsEvents = false
    var bytes = 0
    var overflowed = false
  }

  private let state = Mutex(State())

  /// Starts a new consumer generation. Events from a cancelled generation
  /// are rejected even if its async iterator resumes once after cancellation.
  func beginConsumer() -> UInt64 {
    state.withLock { state in
      state.generation &+= 1
      state.acceptsEvents = true
      state.overflowed = false
      state.events.removeAll(keepingCapacity: true)
      state.bytes = 0
      return state.generation
    }
  }

  /// Returns true only for the event that changed the buffer from empty to
  /// non-empty. A stale consumer returns false and cannot re-arm presentation.
  @discardableResult
  func append(_ event: ServerSessionStreamEvent, cursor: Int? = nil, generation: UInt64, byteCount: Int = 1024) -> Bool
  {
    state.withLock { state in
      guard state.acceptsEvents, state.generation == generation else { return false }
      guard !state.overflowed else { return false }
      if state.events.count >= 512 || state.bytes + byteCount > 512 * 1024 {
        state.overflowed = true
        state.events.removeAll(keepingCapacity: true)
        state.bytes = 0
        return false
      }
      let needsWakeup = state.events.isEmpty
      state.events.append(SessionPendingStreamEvent(event, cursor: cursor))
      state.bytes += byteCount
      return needsWakeup
    }
  }

  var isEmpty: Bool {
    state.withLock { $0.events.isEmpty }
  }

  var overflowed: Bool { state.withLock { $0.overflowed } }

  func accepts(generation: UInt64) -> Bool {
    state.withLock { $0.acceptsEvents && $0.generation == generation }
  }

  func takeAll() -> [SessionPendingStreamEvent] {
    state.withLock { state in
      let events = state.events
      state.events.removeAll(keepingCapacity: true)
      state.bytes = 0
      return events
    }
  }

  func invalidateConsumer(keepingCapacity: Bool = true) {
    state.withLock { state in
      state.generation &+= 1
      state.acceptsEvents = false
      state.overflowed = false
      state.bytes = 0
      state.events.removeAll(keepingCapacity: keepingCapacity)
    }
  }
}

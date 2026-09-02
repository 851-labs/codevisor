import ACPKit
import Synchronization

/// Thread-safe ingress for the live ACP stream.
///
/// The socket consumer writes here without entering the main actor. Only the
/// transition from empty to non-empty schedules UI work, so a burst containing
/// hundreds of token events costs one main-actor wakeup before the next
/// presentation frame.
final class SessionEventBuffer: Sendable {
  private struct State: Sendable {
    var events: [ServerSessionStreamEvent] = []
    var generation: UInt64 = 0
    var acceptsEvents = false
  }

  private let state = Mutex(State())

  /// Starts a new consumer generation. Events from a cancelled generation
  /// are rejected even if its async iterator resumes once after cancellation.
  func beginConsumer() -> UInt64 {
    state.withLock { state in
      state.generation &+= 1
      state.acceptsEvents = true
      return state.generation
    }
  }

  /// Returns true only for the event that changed the buffer from empty to
  /// non-empty. A stale consumer returns false and cannot re-arm presentation.
  @discardableResult
  func append(_ event: ServerSessionStreamEvent, generation: UInt64) -> Bool {
    state.withLock { state in
      guard state.acceptsEvents, state.generation == generation else { return false }
      let needsWakeup = state.events.isEmpty
      state.events.append(event)
      return needsWakeup
    }
  }

  var isEmpty: Bool {
    state.withLock { $0.events.isEmpty }
  }

  func takeAll() -> [ServerSessionStreamEvent] {
    state.withLock { state in
      let events = state.events
      state.events.removeAll(keepingCapacity: true)
      return events
    }
  }

  func invalidateConsumer(keepingCapacity: Bool = true) {
    state.withLock { state in
      state.generation &+= 1
      state.acceptsEvents = false
      state.events.removeAll(keepingCapacity: keepingCapacity)
    }
  }
}

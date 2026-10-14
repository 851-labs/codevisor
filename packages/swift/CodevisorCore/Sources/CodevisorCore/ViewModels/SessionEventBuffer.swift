import ACPKit
import Synchronization

struct SessionPendingStreamEvent: Equatable, Sendable {
  var event: ServerSessionStreamEvent
  var cursor: Int?

  init(_ event: ServerSessionStreamEvent, cursor: Int? = nil) {
    self.event = event
    self.cursor = cursor
  }
}

final class SessionEventBuffer: Sendable {
  private struct State: Sendable {
    var events: [SessionPendingStreamEvent] = []
    var generation: UInt64 = 0
    var acceptsEvents = false
    var bytes = 0
    var overflowed = false
  }

  private let state = Mutex(State())

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

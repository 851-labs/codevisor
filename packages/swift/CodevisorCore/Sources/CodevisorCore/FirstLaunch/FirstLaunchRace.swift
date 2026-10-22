import Synchronization

enum FirstLaunchRace {
  static func first<Value: Sendable>(_ contenders: [@Sendable () async -> Value]) async -> Value {
    let finish = FirstLaunchRaceFinish<Value>()
    return await withCheckedContinuation { continuation in
      finish.begin(continuation)
      for contender in contenders {
        finish.track(Task { finish.resolve(await contender()) })
      }
    }
  }
}

private final class FirstLaunchRaceFinish<Value: Sendable>: Sendable {
  private struct State {
    var continuation: CheckedContinuation<Value, Never>?
    var contenders: [Task<Void, Never>] = []
    var isResolved = false
  }

  private let state = Mutex(State())

  func begin(_ continuation: CheckedContinuation<Value, Never>) {
    state.withLock { $0.continuation = continuation }
  }

  func track(_ contender: Task<Void, Never>) {
    let isLate = state.withLock { state in
      if !state.isResolved { state.contenders.append(contender) }
      return state.isResolved
    }
    if isLate { contender.cancel() }
  }

  func resolve(_ value: Value) {
    let resolution = state.withLock { state in
      guard !state.isResolved else { return Resolution() }
      let resolution = Resolution(continuation: state.continuation, losers: state.contenders)
      state = State(isResolved: true)
      return resolution
    }
    resolution.continuation?.resume(returning: value)
    resolution.losers.forEach { $0.cancel() }
  }

  private struct Resolution {
    var continuation: CheckedContinuation<Value, Never>?
    var losers: [Task<Void, Never>] = []
  }
}

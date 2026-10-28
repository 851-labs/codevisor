import Foundation
import Observation

@MainActor
enum ObservedState {
  static func first<Value>(_ evaluate: () -> Value?) async -> Value? {
    while !Task.isCancelled {
      let change = ObservedChange()
      if let value = withObservationTracking(evaluate, onChange: { change.signal() }) { return value }
      await change.wait()
    }
    return nil
  }
}

private final class ObservedChange: @unchecked Sendable {
  private let lock = NSLock()
  private var hasChanged = false
  private var continuation: CheckedContinuation<Void, Never>?

  func signal() {
    let waiting = lock.withLock {
      hasChanged = true
      defer { continuation = nil }
      return continuation
    }
    waiting?.resume()
  }

  func wait() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let changedAlready = lock.withLock {
          if !hasChanged { self.continuation = continuation }
          return hasChanged
        }
        if changedAlready { continuation.resume() }
      }
    } onCancel: {
      signal()
    }
  }
}

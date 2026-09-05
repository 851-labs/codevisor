import Observation

/// Suspends until a condition over observable state becomes true. Registering
/// the observation and reading the condition are one synchronous operation.
@MainActor
public func awaitObserved(_ condition: () -> Bool) async {
  while true {
    let changed = TestSignal()
    let satisfied = withObservationTracking(condition, onChange: { changed.signal() })
    if satisfied { return }
    await changed.wait()
  }
}

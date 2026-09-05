import Observation

/// Suspends until a condition over observable state becomes true. Recheck after
/// registration: another executor can mutate a fixture between reading its
/// state and Observation installing the observer.
@MainActor
public func awaitObserved(_ condition: () -> Bool) async {
  while true {
    let changed = TestSignal()
    let satisfied = withObservationTracking(condition, onChange: { changed.signal() })
    if satisfied || condition() { return }
    await changed.wait()
  }
}

import Observation

@MainActor
public func awaitObserved(_ condition: () -> Bool) async {
  while !Task.isCancelled {
    let changed = TestSignal()
    let satisfied = withObservationTracking(condition, onChange: { changed.signal() })
    if satisfied || condition() { return }
    await changed.cancellableWait()
  }
}

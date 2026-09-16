import Foundation

/// Polls a condition over lock-protected (non-observable) fixture state, such
/// as a loopback server's message log, until it holds or the timeout passes.
/// Prefer `awaitObserved` for `@Observable` state.
@MainActor
public func awaitPolled(
  timeout: Duration = .seconds(5), interval: Duration = .milliseconds(5), _ condition: () -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while clock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: interval)
  }
  return condition()
}

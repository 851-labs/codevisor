import Foundation

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

import ScreenSharing
import Synchronization

final class ScreenSharingVCPSelfTestOutputs: Sendable {
  typealias Outputs = [ScreenSharingTileEncoderOutput]
  typealias Waiter = CheckedContinuation<Outputs, any Error>

  private struct State {
    let expected: Int
    var outputs: Outputs = []
    var waiter: Waiter?
    var expired = false

    var isComplete: Bool { outputs.count >= expected }

    mutating func append(_ output: ScreenSharingTileEncoderOutput) -> Waiter? {
      outputs.append(output)
      guard isComplete else { return nil }

      defer { waiter = nil }
      return waiter
    }

    mutating func expire() -> Waiter? {
      expired = true
      defer { waiter = nil }
      return waiter
    }
  }

  private let state: Mutex<State>

  init(expected: Int) {
    state = Mutex(State(expected: expected))
  }

  func add(_ output: ScreenSharingTileEncoderOutput) {
    guard let waiter = state.withLock({ $0.append(output) }) else { return }

    waiter.resume(returning: state.withLock { $0.outputs })
  }

  func all(within timeout: Duration) async throws -> Outputs {
    let timer = Task { [weak self] in
      try await Task.sleep(for: timeout)
      self?.expire()
    }
    defer { timer.cancel() }

    return try await withCheckedThrowingContinuation(wait)
  }

  private func wait(_ continuation: Waiter) {
    let (complete, expired) = state.withLock { state in
      if !state.isComplete, !state.expired { state.waiter = continuation }
      return (state.isComplete, state.expired)
    }
    if complete { return continuation.resume(returning: state.withLock { $0.outputs }) }
    if expired { continuation.resume(throwing: Self.timedOut) }
  }

  private func expire() {
    state.withLock { $0.expire() }?.resume(throwing: Self.timedOut)
  }

  private static let timedOut = ScreenSharingError.unavailable("VCP self-test timed out.")
}

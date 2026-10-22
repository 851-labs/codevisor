import CodevisorTestSupport
import Foundation

final class FakeTranscriptPageFaults: @unchecked Sendable {
  let held = TestSignal()
  let release = TestSignal()
  private let lock = NSLock()
  private var failuresRemaining = 0
  private var failure: any Error = URLError(.networkConnectionLost)
  private var holdsNext = false

  func failNext(_ count: Int, with error: any Error) {
    lock.withLock {
      failuresRemaining = count
      failure = error
    }
  }

  func clear() {
    lock.withLock { failuresRemaining = 0 }
  }

  func holdNext() {
    lock.withLock { holdsNext = true }
  }

  func apply() async throws {
    if let failure = takeFailure() { throw failure }
    guard takeHold() else { return }

    held.signal()
    await release.wait()
  }

  private func takeFailure() -> (any Error)? {
    lock.withLock {
      guard failuresRemaining > 0 else { return nil }
      failuresRemaining -= 1
      return failure
    }
  }

  private func takeHold() -> Bool {
    lock.withLock {
      let holds = holdsNext
      holdsNext = false
      return holds
    }
  }
}

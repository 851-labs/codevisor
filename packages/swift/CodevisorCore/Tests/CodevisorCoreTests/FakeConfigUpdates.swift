import ACPKit
import Foundation
import Observation

@Observable
final class FakeConfigUpdates: @unchecked Sendable {
  var handler: (@Sendable (String, String) async throws -> [SessionConfigOption]?)?
  private let lock = NSLock()
  private var updates: [(String, String)] = []
  private var gate: AsyncStream<Void>?
  private var failsNext = false

  var recorded: [(String, String)] {
    lock.withLock { updates }
  }

  func hold(until gate: AsyncStream<Void>) {
    lock.withLock { self.gate = gate }
  }

  func failNext() {
    lock.withLock { failsNext = true }
  }

  func record(configId: String, value: String) -> (gate: AsyncStream<Void>?, fails: Bool) {
    lock.withLock {
      updates.append((configId, value))
      let fails = failsNext
      failsNext = false
      return (gate, fails)
    }
  }
}

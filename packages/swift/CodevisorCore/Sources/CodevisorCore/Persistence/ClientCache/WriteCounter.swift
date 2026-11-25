import Foundation

final class WriteCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() -> Int {
    lock.withLock {
      count += 1
      return count
    }
  }

  func reset() {
    lock.withLock { count = 0 }
  }
}

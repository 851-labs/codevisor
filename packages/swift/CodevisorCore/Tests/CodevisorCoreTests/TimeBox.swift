import Foundation

/// A clock that returns scripted timestamps in order, repeating the last value.
final class TimeBox: @unchecked Sendable {
  private let values: [Date]
  private var index = 0
  private let lock = NSLock()
  init(values: [Date]) { self.values = values }
  func next() -> Date {
    lock.withLock {
      let value = values[min(index, values.count - 1)]
      index += 1
      return value
    }
  }
}

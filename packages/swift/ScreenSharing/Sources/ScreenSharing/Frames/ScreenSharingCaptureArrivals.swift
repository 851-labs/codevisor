import Foundation

package final class ScreenSharingCaptureArrivals: @unchecked Sendable {
  private struct Arrival {
    var sourceTimestampNs: Int64
    var arrivedNs: Int64
  }

  private static let capacity = 16
  private static let empty = Arrival(sourceTimestampNs: -1, arrivedNs: 0)
  private let lock = NSLock()
  private var arrivals = [Arrival](repeating: empty, count: capacity)
  private var next = 0

  package init() {}

  package func record(sourceTimestampNs: Int64, arrivedNs: Int64) {
    lock.withLock {
      arrivals[next] = Arrival(sourceTimestampNs: sourceTimestampNs, arrivedNs: arrivedNs)
      next = (next + 1) % Self.capacity
    }
  }

  package func take(sourceTimestampNs: Int64) -> Int64? {
    lock.withLock {
      guard let index = arrivals.firstIndex(where: { $0.sourceTimestampNs == sourceTimestampNs }) else { return nil }

      let arrival = arrivals[index]
      arrivals[index] = Self.empty
      return arrival.arrivedNs
    }
  }
}

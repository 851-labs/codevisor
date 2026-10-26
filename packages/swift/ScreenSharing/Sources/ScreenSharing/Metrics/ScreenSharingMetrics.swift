import Foundation

public final class ScreenSharingMetrics: @unchecked Sendable {
  private let lock = NSLock()
  private var counterValues: [String: Int] = [:]
  private var labelValues: [String: String] = [:]
  private var samples: [String: [Double]] = [:]
  private var indices: [String: Int] = [:]
  private var previousEvents: [String: Int64] = [:]
  private let capacity = 1800

  public init() {}
  public static var nowNs: Int64 { Int64(DispatchTime.now().uptimeNanoseconds) }

  @discardableResult
  public func increment(_ name: String, by count: Int = 1) -> Int {
    lock.withLock {
      counterValues[name, default: 0] += count
      return counterValues[name, default: 0]
    }
  }

  public func label(_ name: String, _ value: String) {
    lock.withLock { labelValues[name] = value }
  }

  public func counter(_ name: String) -> Int { lock.withLock { counterValues[name, default: 0] } }
  public func label(_ name: String) -> String? { lock.withLock { labelValues[name] } }
  public func counters() -> [String: Int] { lock.withLock { counterValues } }

  public func observe(_ name: String, milliseconds: Double) {
    guard milliseconds.isFinite, milliseconds >= 0 else { return }
    lock.withLock {
      if samples[name, default: []].count < capacity {
        samples[name, default: []].append(milliseconds)
      } else {
        let index = indices[name, default: 0]
        samples[name]?[index] = milliseconds
        indices[name] = (index + 1) % capacity
      }
    }
  }

  public func event(_ name: String, atNanoseconds timestamp: Int64) {
    guard timestamp >= 0 else { return }
    let elapsed: Double? = lock.withLock {
      let previous = previousEvents.updateValue(timestamp, forKey: name)
      guard let previous, timestamp >= previous else { return nil }
      return Double(timestamp - previous) / 1_000_000
    }
    if let elapsed { observe(name, milliseconds: elapsed) }
  }

  public struct Snapshot: Codable, Sendable {
    public let counters: [String: Int]
    public let labels: [String: String]
    public let timings: [String: Timing]
  }

  public struct Timing: Codable, Sendable {
    public let count: Int
    public let p50Ms: Double
    public let p95Ms: Double
    public let maximumMs: Double
  }

  public func snapshot() -> Snapshot {
    let (counters, labels, samples) = lock.withLock {
      (counterValues, labelValues, samples.mapValues { $0.withUnsafeBufferPointer(Array.init) })
    }
    return Snapshot(counters: counters, labels: labels, timings: samples.mapValues(Self.timing))
  }

  private static func timing(_ values: [Double]) -> Timing {
    let sorted = values.sorted()
    return Timing(
      count: sorted.count, p50Ms: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.5))],
      p95Ms: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], maximumMs: sorted.last ?? 0)
  }
}

import Foundation

/// Bounded measurements from a single process's monotonic clock. No remote
/// clock subtraction: network and input-to-photon measurements are separate.
public final class ScreenSharingMetrics: @unchecked Sendable {
  private let lock = NSLock()
  private var counterValues: [String: Int] = [:]
  private var labelValues: [String: String] = [:]
  private var samples: [String: [Double]] = [:]
  private var indices: [String: Int] = [:]
  private var previousEvents: [String: Int64] = [:]
  private var traces: [String: [String]] = [:]
  private var tracing = false
  private let capacity = 1800
  private let traceCapacity = 64

  public init() {}
  public static var nowNs: Int64 { Int64(DispatchTime.now().uptimeNanoseconds) }

  /// Returns the new value so callers can label first occurrences atomically.
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

  /// One counter (0 before its first increment), one label, or every counter: what a
  /// once-a-second check reads without building a whole `snapshot()`.
  public func counter(_ name: String) -> Int { lock.withLock { counterValues[name, default: 0] } }
  public func label(_ name: String) -> String? { lock.withLock { labelValues[name] } }
  public func counters() -> [String: Int] { lock.withLock { counterValues } }

  /// Probe-only boundary tracing. Disabled by default: the entry autoclosure
  /// is never evaluated, so no string is built on media paths in the app.
  public func enableTracing() { lock.withLock { tracing = true } }
  public var isTracing: Bool { lock.withLock { tracing } }

  /// Bounded ordered diagnostic events (newest 64 per name) for boundary
  /// tracing; a single string per event keeps the cost to one lock and copy.
  public func trace(_ name: String, _ entry: @autoclosure () -> String) {
    guard isTracing else { return }
    let value = entry()
    lock.withLock {
      if traces[name, default: []].count == traceCapacity { traces[name]?.removeFirst() }
      traces[name, default: []].append(value)
    }
  }

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

  /// Cadence within one stage and clock. Repeated timestamps are valid zero
  /// intervals; backwards timestamps reset the baseline without a huge sample.
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
    public let traces: [String: [String]]?
  }

  public struct Timing: Codable, Sendable {
    public let count: Int
    public let p50Ms: Double
    public let p95Ms: Double
    public let maximumMs: Double
  }

  /// Copies the samples under the lock and sorts them outside it: capture, encode, decode and render
  /// threads take the same lock for every frame.
  public func snapshot() -> Snapshot {
    let (counters, labels, samples, traces) = lock.withLock {
      // A copy of its own, so the next sample written isn't the one that pays to copy the series.
      (counterValues, labelValues, samples.mapValues { $0.withUnsafeBufferPointer(Array.init) }, traces)
    }
    return Snapshot(
      counters: counters, labels: labels, timings: samples.mapValues(Self.timing),
      traces: traces.isEmpty ? nil : traces)
  }

  private static func timing(_ values: [Double]) -> Timing {
    let sorted = values.sorted()
    return Timing(
      count: sorted.count, p50Ms: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.5))],
      p95Ms: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], maximumMs: sorted.last ?? 0)
  }
}

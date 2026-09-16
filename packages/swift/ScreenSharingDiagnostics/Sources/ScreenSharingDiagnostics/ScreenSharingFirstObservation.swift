import CodevisorScreenSharing
import Foundation

/// Pure semantics for the owned-window diagnostic's observations. Platform
/// neutral so they are testable; the probe supplies the measured values.

/// First-observed delivery over the probe's measurement ticks (≈1 s). Each
/// metric records the first tick at which its counter became non-zero, plus
/// the initial and final values. Resolution is the tick, never a callback or
/// presentation timestamp; a metric that never became non-zero stays
/// explicitly "never observed". Bounded: one entry per metric, no history.
public struct ScreenSharingFirstObservation: Sendable {
  public struct Metric: Equatable, Sendable {
    public var initialValue: Int?
    public var finalValue: Int?
    public var firstObservedTick: Int?
    public var firstObservedAtSeconds: Double?
    public var valueWhenFirstObserved: Int?
  }

  public static let resolution = "measurement tick (about 1 s); not a callback, delivery or presentation timestamp"
  public static let neverObserved = "never observed"
  public private(set) var metrics: [String: Metric] = [:]
  public private(set) var ticks = 0

  public init(names: [String]) {
    for name in names { metrics[name] = Metric() }
  }

  /// Records one tick of counter values. Returns the metric names that became
  /// non-zero for the first time on this tick, in sorted-name order.
  @discardableResult
  public mutating func record(elapsedSeconds: Double, values: [String: Int]) -> [String] {
    let tick = ticks
    ticks += 1
    var newlyObserved: [String] = []
    for name in metrics.keys.sorted() {
      guard var metric = metrics[name] else { continue }
      let value = values[name] ?? 0
      if metric.initialValue == nil { metric.initialValue = value }
      metric.finalValue = value
      if metric.firstObservedTick == nil, value > 0 {
        metric.firstObservedTick = tick
        metric.firstObservedAtSeconds = elapsedSeconds
        metric.valueWhenFirstObserved = value
        newlyObserved.append(name)
      }
      metrics[name] = metric
    }
    return newlyObserved
  }

  /// Serialisable summary with explicit never-observed values.
  public var summary: [String: [String: String]] {
    var result: [String: [String: String]] = [:]
    for (name, metric) in metrics {
      result[name] = [
        "initialValue": metric.initialValue.map(String.init) ?? "not recorded",
        "finalValue": metric.finalValue.map(String.init) ?? "not recorded",
        "firstObservedAtSeconds": metric.firstObservedAtSeconds.map { String($0) } ?? Self.neverObserved,
        "firstObservedTick": metric.firstObservedTick.map(String.init) ?? Self.neverObserved,
        "valueWhenFirstObserved": metric.valueWhenFirstObserved.map(String.init) ?? Self.neverObserved,
        "resolution": Self.resolution,
      ]
    }
    return result
  }
}

/// Own-window geometry and identity records. Coordinates are kept in their
/// native conventions; the one conversion is explicit about the display
/// height it uses.
public enum ScreenSharingOwnedWindowGeometry {
  public struct Rect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
      self.x = x; self.y = y; self.width = width; self.height = height
    }
  }

  /// A CGWindowList entry reduced to the fields the diagnostic persists.
  public struct WindowListEntry: Equatable, Sendable {
    public var number: UInt32
    public var ownerPID: Int32?
    public var bounds: Rect?
    public var layer: Int?
    public var isOnscreen: Bool?
    public var alpha: Double?
    public init(number: UInt32, ownerPID: Int32?, bounds: Rect?, layer: Int?, isOnscreen: Bool?, alpha: Double?) {
      self.number = number; self.ownerPID = ownerPID; self.bounds = bounds; self.layer = layer;
      self.isOnscreen = isOnscreen; self.alpha = alpha
    }
  }

  /// Cocoa (origin bottom-left of the main display) → CG global top-left,
  /// using the MAIN display's height (`CGDisplayBounds(CGMainDisplayID())`):
  /// y' = mainDisplayHeight − (y + height). Only valid with that height.
  public static func cocoaToTopLeft(_ frame: Rect, mainDisplayHeight: Double) -> Rect {
    Rect(x: frame.x, y: mainDisplayHeight - (frame.y + frame.height), width: frame.width, height: frame.height)
  }

  /// Exactly one entry with the own window number AND the own pid; every other
  /// outcome is an explicit state, never a guess: the query itself unavailable
  /// (nil), no entry with that number, an exact-number entry whose owner the
  /// window server did not report, an exact-number entry owned by another pid,
  /// or duplicates. Only a `found` entry's fields may be persisted.
  public enum Selection: Equatable, Sendable {
    case found(WindowListEntry)
    case queryUnavailable
    case absent
    case ownerUnreported
    case ownerMismatch(reportedPID: Int32)
    case duplicate(count: Int)
  }

  public static func ownWindow(in entries: [WindowListEntry]?, number: UInt32, pid: Int32) -> Selection {
    guard let entries else { return .queryUnavailable }
    let matching = entries.filter { $0.number == number }
    guard !matching.isEmpty else { return .absent }
    guard matching.count == 1, let entry = matching.first else { return .duplicate(count: matching.count) }
    guard let owner = entry.ownerPID else { return .ownerUnreported }
    guard owner == pid else { return .ownerMismatch(reportedPID: owner) }
    return .found(entry)
  }
}

/// Bounded record of the first AppKit draw-call start per marker code — the
/// exact semantics the image-age analyzer consumes: one entry per code, kept
/// only when the code differs from the previously recorded one (a repeated
/// code, e.g. a frozen paused workload, is not re-recorded), at most `limit`
/// entries with an explicit truncation flag. Draw-call starts are CPU timing,
/// not presentation.
public struct ScreenSharingDrawTimestampRecord: Sendable {
  public struct Sample: Equatable, Sendable {
    public let code: Int
    public let startedAtSeconds: Double
    public init(code: Int, startedAtSeconds: Double) {
      self.code = code
      self.startedAtSeconds = startedAtSeconds
    }
  }

  public static let defaultLimit = 20_000
  public let limit: Int
  public private(set) var samples: [Sample] = []
  public private(set) var truncated = false

  public init(limit: Int = ScreenSharingDrawTimestampRecord.defaultLimit) { self.limit = max(1, limit) }

  /// Records a draw start; returns true when a new entry was retained.
  @discardableResult
  public mutating func record(code: Int, startedAtSeconds: Double) -> Bool {
    guard samples.last?.code != code else { return false }
    guard samples.count < limit else {
      truncated = true
      return false
    }
    samples.append(Sample(code: code, startedAtSeconds: startedAtSeconds))
    return true
  }
}

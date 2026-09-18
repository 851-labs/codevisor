import ScreenSharing
import ScreenSharingWebRTC
import Foundation

/// Pure semantics for the owned-window diagnostic's observations. Platform
/// neutral so they are testable; the probe supplies the measured values.

/// First-observed delivery over the probe's measurement ticks (≈1 s). Each
/// metric records the first tick at which its counter became non-zero, plus
/// the initial and final values. Resolution is the tick, never a callback or
/// presentation timestamp; a metric that never became non-zero stays
/// explicitly "never observed". Bounded: one entry per metric, no history.
package struct ScreenSharingFirstObservation: Sendable {
  package struct Metric: Equatable, Sendable {
    package var initialValue: Int?
    package var finalValue: Int?
    package var firstObservedTick: Int?
    package var firstObservedAtSeconds: Double?
    package var valueWhenFirstObserved: Int?
  }

  package static let resolution = "measurement tick (about 1 s); not a callback, delivery or presentation timestamp"
  package static let neverObserved = "never observed"
  public private(set) var metrics: [String: Metric] = [:]
  public private(set) var ticks = 0

  package init(names: [String]) {
    for name in names { metrics[name] = Metric() }
  }

  /// Records one tick of counter values. Returns the metric names that became
  /// non-zero for the first time on this tick, in sorted-name order.
  @discardableResult
  package mutating func record(elapsedSeconds: Double, values: [String: Int]) -> [String] {
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
  package var summary: [String: [String: String]] {
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
package enum ScreenSharingOwnedWindowGeometry {
  package struct Rect: Equatable, Sendable {
    package var x: Double, y: Double, width: Double, height: Double
    package init(x: Double, y: Double, width: Double, height: Double) {
      self.x = x; self.y = y; self.width = width; self.height = height
    }
  }

  /// A CGWindowList entry reduced to the fields the diagnostic persists.
  package struct WindowListEntry: Equatable, Sendable {
    package var number: UInt32
    package var ownerPID: Int32?
    package var bounds: Rect?
    package var layer: Int?
    package var isOnscreen: Bool?
    package var alpha: Double?
    package init(number: UInt32, ownerPID: Int32?, bounds: Rect?, layer: Int?, isOnscreen: Bool?, alpha: Double?) {
      self.number = number; self.ownerPID = ownerPID; self.bounds = bounds; self.layer = layer;
      self.isOnscreen = isOnscreen; self.alpha = alpha
    }
  }

  /// Cocoa (origin bottom-left of the main display) → CG global top-left,
  /// using the MAIN display's height (`CGDisplayBounds(CGMainDisplayID())`):
  /// y' = mainDisplayHeight − (y + height). Only valid with that height.
  package static func cocoaToTopLeft(_ frame: Rect, mainDisplayHeight: Double) -> Rect {
    Rect(x: frame.x, y: mainDisplayHeight - (frame.y + frame.height), width: frame.width, height: frame.height)
  }

  /// Exactly one entry with the own window number AND the own pid; every other
  /// outcome is an explicit state, never a guess: the query itself unavailable
  /// (nil), no entry with that number, an exact-number entry whose owner the
  /// window server did not report, an exact-number entry owned by another pid,
  /// or duplicates. Only a `found` entry's fields may be persisted.
  package enum Selection: Equatable, Sendable {
    case found(WindowListEntry)
    case queryUnavailable
    case absent
    case ownerUnreported
    case ownerMismatch(reportedPID: Int32)
    case duplicate(count: Int)
  }

  package static func ownWindow(in entries: [WindowListEntry]?, number: UInt32, pid: Int32) -> Selection {
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
package struct ScreenSharingDrawTimestampRecord: Sendable {
  package struct Sample: Equatable, Sendable {
    package let code: Int
    package let startedAtSeconds: Double
    package init(code: Int, startedAtSeconds: Double) {
      self.code = code
      self.startedAtSeconds = startedAtSeconds
    }
  }

  package static let defaultLimit = 20_000
  package let limit: Int
  public private(set) var samples: [Sample] = []
  public private(set) var truncated = false

  package init(limit: Int = ScreenSharingDrawTimestampRecord.defaultLimit) { self.limit = max(1, limit) }

  /// Records a draw start; returns true when a new entry was retained.
  @discardableResult
  package mutating func record(code: Int, startedAtSeconds: Double) -> Bool {
    guard samples.last?.code != code else { return false }
    guard samples.count < limit else {
      truncated = true
      return false
    }
    samples.append(Sample(code: code, startedAtSeconds: startedAtSeconds))
    return true
  }
}

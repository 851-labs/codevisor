import CoreGraphics
import Foundation

/// Chooses a stable, geometry-based render window around the native viewport.
///
/// A small inner guard band provides hysteresis: scrolling inside an already
/// prepared window does not churn hosts. Once the viewport reaches that guard,
/// the window advances by a larger, directionally-biased runway. A bounded
/// prediction term covers fast single-frame jumps without allowing one event
/// to mount an unbounded portion of the transcript.
public struct TranscriptVirtualWindowPolicy: Sendable, Equatable {
  public let guardBandViewportCount: CGFloat
  public let runwayBehindViewportCount: CGFloat
  public let runwayAheadViewportCount: CGFloat
  public let stationaryRunwayViewportCount: CGFloat
  public let predictionMultiplier: CGFloat
  public let maximumPredictionViewportCount: CGFloat

  public init(
    guardBandViewportCount: CGFloat = 0.75,
    runwayBehindViewportCount: CGFloat = 1.25,
    runwayAheadViewportCount: CGFloat = 3,
    stationaryRunwayViewportCount: CGFloat = 2,
    predictionMultiplier: CGFloat = 2.5,
    maximumPredictionViewportCount: CGFloat = 3
  ) {
    self.guardBandViewportCount = max(0, guardBandViewportCount)
    self.runwayBehindViewportCount = max(0, runwayBehindViewportCount)
    self.runwayAheadViewportCount = max(0, runwayAheadViewportCount)
    self.stationaryRunwayViewportCount = max(0, stationaryRunwayViewportCount)
    self.predictionMultiplier = max(0, predictionMultiplier)
    self.maximumPredictionViewportCount = max(0, maximumPredictionViewportCount)
  }

  /// Returns the existing window while its guard band still contains the
  /// viewport. Otherwise, returns a new pixel runway biased in the direction
  /// of travel. `scrollDelta` uses document coordinates: negative moves
  /// toward the transcript's start, positive toward its end.
  public func targetRange(
    layout: VirtualTranscriptLayout,
    distanceFromBottom: CGFloat,
    viewportHeight: CGFloat,
    scrollDelta: CGFloat,
    currentRange: Range<Int>?
  ) -> Range<Int> {
    guard !layout.isEmpty else { return 0..<0 }
    let viewportHeight = max(1, viewportHeight)
    let guardRunway = viewportHeight * guardBandViewportCount
    let prediction = min(
      abs(scrollDelta) * predictionMultiplier,
      viewportHeight * maximumPredictionViewportCount
    )
    let requiredRunwayBefore = guardRunway + (scrollDelta < -0.5 ? prediction : 0)
    let requiredRunwayAfter = guardRunway + (scrollDelta > 0.5 ? prediction : 0)
    let requiredRange = layout.visibleRange(
      distanceFromBottom: distanceFromBottom,
      viewportHeight: viewportHeight,
      runwayBefore: requiredRunwayBefore,
      runwayAfter: requiredRunwayAfter
    )
    if let currentRange,
      currentRange.lowerBound >= 0,
      currentRange.upperBound <= layout.keys.count,
      currentRange.lowerBound <= requiredRange.lowerBound,
      currentRange.upperBound >= requiredRange.upperBound
    {
      return currentRange
    }

    let runwayBefore: CGFloat
    let runwayAfter: CGFloat
    if scrollDelta < -0.5 {
      runwayBefore = viewportHeight * runwayAheadViewportCount + prediction
      runwayAfter = viewportHeight * runwayBehindViewportCount
    } else if scrollDelta > 0.5 {
      runwayBefore = viewportHeight * runwayBehindViewportCount
      runwayAfter = viewportHeight * runwayAheadViewportCount + prediction
    } else {
      runwayBefore = viewportHeight * stationaryRunwayViewportCount
      runwayAfter = viewportHeight * stationaryRunwayViewportCount
    }
    return layout.visibleRange(
      distanceFromBottom: distanceFromBottom,
      viewportHeight: viewportHeight,
      runwayBefore: runwayBefore,
      runwayAfter: runwayAfter
    )
  }

  /// Splits mounting into mandatory viewport coverage and speculative runway
  /// preparation. Adapters must mount every `visibleIndex` before presenting
  /// the frame; only `runwayIndices` may be subject to a frame budget.
  public func mountPlan(
    targetRange: Range<Int>,
    visibleRange: Range<Int>,
    scrollDelta: CGFloat
  ) -> TranscriptVirtualWindowMountPlan {
    guard !targetRange.isEmpty else { return .empty }
    let beforeUpper = min(
      targetRange.upperBound,
      max(targetRange.lowerBound, visibleRange.lowerBound)
    )
    let afterLower = min(
      targetRange.upperBound,
      max(targetRange.lowerBound, visibleRange.upperBound)
    )
    let before = Array(targetRange.lowerBound..<beforeUpper).reversed()
    let after = Array(afterLower..<targetRange.upperBound)
    let runway: [Int]
    if scrollDelta < -0.5 {
      runway = Array(before) + after
    } else {
      runway = after + before
    }
    return TranscriptVirtualWindowMountPlan(
      visibleIndices: Array(visibleRange),
      runwayIndices: runway
    )
  }
}

/// Tracks scroll direction and a short velocity projection for runway work.
/// The projection survives the individual bounds notifications that produced
/// it, allowing follow-up display frames to keep preparing the same direction.
public struct TranscriptRunwayMotion: Sendable, Equatable {
  public private(set) var pointsPerSecond: CGFloat = 0
  private var lastViewportTop: CGFloat?
  private var lastTimestamp: TimeInterval?

  public init() {}

  public mutating func observe(viewportTop: CGFloat, timestamp: TimeInterval) {
    defer {
      lastViewportTop = viewportTop
      lastTimestamp = timestamp
    }
    guard let lastViewportTop, let lastTimestamp else { return }
    let elapsed = timestamp - lastTimestamp
    guard elapsed > 0, elapsed <= 0.25 else {
      pointsPerSecond = 0
      return
    }
    let instantaneousVelocity = (viewportTop - lastViewportTop) / elapsed
    guard abs(instantaneousVelocity) > 1 else { return }
    if pointsPerSecond == 0 || pointsPerSecond.sign != instantaneousVelocity.sign {
      pointsPerSecond = instantaneousVelocity
    } else {
      pointsPerSecond = pointsPerSecond * 0.55 + instantaneousVelocity * 0.45
    }
  }

  public func projectedDelta(
    timestamp: TimeInterval,
    lookAhead: TimeInterval = 0.18,
    maximumDistance: CGFloat
  ) -> CGFloat {
    guard let lastTimestamp else { return 0 }
    let age = max(0, timestamp - lastTimestamp)
    guard age < 0.25 else { return 0 }
    let decay = CGFloat(1 - age / 0.25)
    let projection = pointsPerSecond * CGFloat(lookAhead) * decay
    let limit = max(0, maximumDistance)
    return min(limit, max(-limit, projection))
  }

  public mutating func reset(viewportTop: CGFloat? = nil, timestamp: TimeInterval? = nil) {
    pointsPerSecond = 0
    lastViewportTop = viewportTop
    lastTimestamp = timestamp
  }
}

/// Work for one virtual-window reconciliation. Viewport coverage is a
/// correctness requirement; runway preparation is a performance optimization.
public struct TranscriptVirtualWindowMountPlan: Sendable, Equatable {
  public static let empty = Self(visibleIndices: [], runwayIndices: [])

  public let visibleIndices: [Int]
  public let runwayIndices: [Int]

  public init(visibleIndices: [Int], runwayIndices: [Int]) {
    self.visibleIndices = visibleIndices
    self.runwayIndices = runwayIndices
  }
}

/// Tracks a two-phase virtual-window transition without knowing anything
/// about AppKit or UIKit hosts. The presented keys remain retained until every
/// target key is ready. Replacing an unfinished target immediately drops that
/// intermediate window from `retainedKeys`, so a fast scroll cannot accumulate
/// an unbounded trail of partially prepared hosts.
public struct TranscriptVirtualWindowHandoff: Sendable, Equatable {
  public private(set) var targetKeys: Set<String> = []
  public private(set) var presentedKeys: Set<String> = []

  public init() {}

  public var retainedKeys: Set<String> {
    presentedKeys.union(targetKeys)
  }

  public mutating func setTarget(_ keys: Set<String>) {
    targetKeys = keys
  }

  public mutating func retainOnlyValidKeys(_ isValid: (String) -> Bool) {
    targetKeys = Set(targetKeys.filter(isValid))
    presentedKeys = Set(presentedKeys.filter(isValid))
  }

  @discardableResult
  public mutating func promoteIfReady(_ isReady: (String) -> Bool) -> Bool {
    guard targetKeys.allSatisfy(isReady) else { return false }
    presentedKeys = targetKeys
    return true
  }

  public mutating func reset() {
    targetKeys.removeAll(keepingCapacity: false)
    presentedKeys.removeAll(keepingCapacity: false)
  }
}

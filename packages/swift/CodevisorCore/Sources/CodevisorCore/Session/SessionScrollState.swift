import Foundation
import TranscriptKit

public struct SessionMeasuredRow: Equatable {
  public var height: CGFloat
  public var revision: Int

  public init(height: CGFloat, revision: Int) {
    self.height = height
    self.revision = revision
  }
}

public struct SessionMeasurementCacheKey: Hashable {
  public var rowWidthHalfPoints: Int
  public var layoutFingerprint: Int

  public init(rowWidthHalfPoints: Int, layoutFingerprint: Int) {
    self.rowWidthHalfPoints = rowWidthHalfPoints
    self.layoutFingerprint = layoutFingerprint
  }
}

public struct SessionRenderedTranscriptWindow: Equatable {
  public var anchorKey: String
  public var count: Int

  public init(anchorKey: String, count: Int) {
    self.anchorKey = anchorKey
    self.count = count
  }
}

public struct SessionVirtualTranscriptRestoreState: Equatable {
  public var measurementCacheKey: SessionMeasurementCacheKey?
  public var rowHeightsByKey: [String: CGFloat]
  public var settledRowsByKey: [String: SessionMeasuredRow] = [:]
  public var renderedWindow: SessionRenderedTranscriptWindow?
  public var viewportAnchor: VirtualTranscriptAnchor?

  public init(
    measurementCacheKey: SessionMeasurementCacheKey?,
    rowHeightsByKey: [String: CGFloat],
    settledRowsByKey: [String: SessionMeasuredRow] = [:],
    renderedWindow: SessionRenderedTranscriptWindow? = nil,
    viewportAnchor: VirtualTranscriptAnchor? = nil
  ) {
    self.measurementCacheKey = measurementCacheKey
    self.rowHeightsByKey = rowHeightsByKey
    self.settledRowsByKey = settledRowsByKey
    self.renderedWindow = renderedWindow
    self.viewportAnchor = viewportAnchor
  }
}

public enum SessionTranscriptFollowMode: Equatable {
  case staticPosition
  case followingLatest

  public var followsLatest: Bool { self == .followingLatest }
}

public struct SessionScrollState {
  public var distanceFromBottom: CGFloat
  public var measurementCaches: [SessionMeasurementCacheKey: [String: SessionMeasuredRow]]
  public var measurementCacheLRU: [SessionMeasurementCacheKey]
  public var virtualTranscript: SessionVirtualTranscriptRestoreState?
  public var followMode: SessionTranscriptFollowMode
  public var isAtBottom: Bool { distanceFromBottom <= 2 }

  public init(
    distanceFromBottom: CGFloat,
    measurementCaches: [SessionMeasurementCacheKey: [String: SessionMeasuredRow]],
    measurementCacheLRU: [SessionMeasurementCacheKey],
    virtualTranscript: SessionVirtualTranscriptRestoreState? = nil,
    followMode: SessionTranscriptFollowMode
  ) {
    self.distanceFromBottom = distanceFromBottom
    self.measurementCaches = measurementCaches
    self.measurementCacheLRU = measurementCacheLRU
    self.virtualTranscript = virtualTranscript
    self.followMode = followMode
  }
}

import Foundation
import TranscriptKit

/// One measured settled-row height. The revision prevents a stale height from
/// being reused if the row's content changed while it was offscreen.
public struct SessionMeasuredRow: Equatable {
  public var height: CGFloat
  public var revision: Int

  public init(height: CGFloat, revision: Int) {
    self.height = height
    self.revision = revision
  }
}

/// Text layout depends on the actual row width and the app's typography. Keep
/// those dimensions in the cache key so a sidebar resize cannot poison a later
/// restoration at another width.
public struct SessionMeasurementCacheKey: Hashable {
  /// Effective row width in half-point buckets. Sub-pixel window jitter does
  /// not create a new cache, while a real reflow does.
  public var rowWidthHalfPoints: Int
  public var layoutFingerprint: Int

  public init(rowWidthHalfPoints: Int, layoutFingerprint: Int) {
    self.rowWidthHalfPoints = rowWidthHalfPoints
    self.layoutFingerprint = layoutFingerprint
  }
}

/// The mounted virtual window saved alongside a transcript coordinate. This
/// mirrors ChatGPT's `renderedWindow`: restoration mounts the same neighborhood
/// before any estimates are allowed to choose a different part of the thread.
public struct SessionRenderedTranscriptWindow: Equatable {
  public var anchorKey: String
  public var count: Int

  public init(anchorKey: String, count: Int) {
    self.anchorKey = anchorKey
    self.count = count
  }
}

/// Virtualizer-owned restore data. The height map is the exact geometry that
/// produced the saved coordinate; the regular LRU remains the longer-lived
/// cache used across width changes.
public struct SessionVirtualTranscriptRestoreState: Equatable {
  public var measurementCacheKey: SessionMeasurementCacheKey?
  public var rowHeightsByKey: [String: CGFloat]
  /// Revisions for the settled subset of `rowHeightsByKey`. Restore applies
  /// a settled row's saved height only when its revision still matches the
  /// current transcript — content can change while a pane is closed (e.g. a
  /// background subagent streaming into an already-ended turn).
  public var settledRowsByKey: [String: SessionMeasuredRow] = [:]
  public var renderedWindow: SessionRenderedTranscriptWindow?
  /// The exact visible block and pixel offset at the viewport's top edge.
  /// This remains stable when estimates elsewhere are replaced by measured
  /// heights; `distanceFromBottom` is retained as a missing-row fallback.
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

/// User intent for how the transcript should react to future content. This is
/// deliberately independent from viewport geometry: restoring or remeasuring
/// rows can move the viewport a few points without meaning that the user chose
/// to stop following the latest turn.
public enum SessionTranscriptFollowMode: Equatable {
  case staticPosition
  case followingLatest

  public var followsLatest: Bool { self == .followingLatest }
}

/// Where the transcript was scrolled when the user last looked at a session,
/// kept on the cached controller so navigating away and back reopens the
/// transcript at the same place instead of pinned to the bottom.
public struct SessionScrollState {
  /// Bottom-relative fallback used when the exact virtual row anchor is no
  /// longer present. Zero means the latest content is visible.
  public var distanceFromBottom: CGFloat
  /// A tiny, bounded LRU of exact settled-row measurements. Dictionary
  /// snapshots are copy-on-write, so publishing scroll state remains O(1).
  public var measurementCaches: [SessionMeasurementCacheKey: [String: SessionMeasuredRow]]
  public var measurementCacheLRU: [SessionMeasurementCacheKey]
  /// Exact virtual window and row geometry from the last mounted view.
  public var virtualTranscript: SessionVirtualTranscriptRestoreState?
  /// Follow intent is persisted separately from the viewport coordinate.
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

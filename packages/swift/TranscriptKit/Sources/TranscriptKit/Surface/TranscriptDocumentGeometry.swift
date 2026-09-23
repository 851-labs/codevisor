import CoreGraphics
import Foundation

/// Document-geometry math shared by the AppKit and UIKit virtualizers:
/// building the layout from rows and the ledger, patching it for a
/// height-only commit, and detecting composer-spacer changes.
public enum TranscriptDocumentGeometry {
  /// A full layout for `rows`, using measured heights where the ledger has
  /// them and row estimates elsewhere.
  public static func layout(
    rows: [TranscriptPresentationRow],
    measurements: TranscriptMeasurementLedger,
    spacing: CGFloat
  ) -> VirtualTranscriptLayout {
    VirtualTranscriptLayout(
      items: rows.map {
        .init(
          key: $0.layoutKey,
          estimatedHeight: $0.estimatedHeight,
          spacingAfter: $0.spacingAfter
        )
      },
      measuredHeights: measurements.heightsByKey,
      spacing: spacing
    )
  }

  /// `current` with only the given heights patched, or nil when a full
  /// rebuild is required (no hint, row set drifted, or a key is unknown).
  /// Guarded so a mismatch can never produce stale geometry: the row count
  /// must match and every changed key must already exist.
  public static func incrementallyUpdatedLayout(
    _ current: VirtualTranscriptLayout,
    rowCount: Int,
    changedHeights: [String: CGFloat]?
  ) -> VirtualTranscriptLayout? {
    guard let changedHeights, !changedHeights.isEmpty,
      !current.isEmpty,
      current.keys.count == rowCount
    else { return nil }
    return current.updatingHeights(changedHeights)
  }

  /// Whether the composer spacer's height is about to move relative to the
  /// layout it was last built into.
  public static func bottomSpacerGeometryWillChange(
    from previousLayout: VirtualTranscriptLayout,
    spacerRow: TranscriptPresentationRow?,
    measurements: TranscriptMeasurementLedger
  ) -> Bool {
    let key = TranscriptPresentationRow.ID.bottomSpacer.layoutKey
    guard let previousIndex = previousLayout.indexByKey[key],
      previousLayout.keys.indices.contains(previousIndex),
      let row = spacerRow
    else { return false }
    let nextHeight = measurements[key] ?? row.estimatedHeight
    return abs(previousLayout.frame(at: previousIndex).height - nextHeight) > 0.5
  }
}

/// Decides, before a document rebuild, how the viewport is re-anchored
/// afterwards. A locked restore target wins until the user deliberately
/// scrolls. A reader who is following the latest content stays pinned to the
/// bottom through every geometry change — rows appended by a turn that
/// started or finished while the chat was not on screen, and their heights
/// settling from estimates to measurements — not only while a row is
/// streaming. Once the reader has scrolled away from the bottom, the first
/// row that starts inside the viewport is preserved instead of a raw bottom
/// distance, so height changes above it, including the partly visible row
/// straddling the viewport top, cannot move what the reader sees.
public struct TranscriptGeometryRebuildPlan: Equatable, Sendable {
  /// The viewport stays at distance zero regardless of row changes.
  public let pinsBottom: Bool
  /// The visible row to keep stationary, when not pinned and not following.
  public let visibleAnchorKey: String?
  /// The bottom distance to restore, or nil before the initial position is
  /// applied.
  public let distanceToPreserve: CGFloat?

  public init(
    previousLayout: VirtualTranscriptLayout,
    previousDistanceFromBottom: CGFloat?,
    viewportHeight: CGFloat,
    followsLatest: Bool,
    lockedRestoreDistance: CGFloat?,
    initialPositionApplied: Bool,
    gatePinsBottom: Bool,
    bottomSpacerWillChange: Bool,
    atBottomThreshold: CGFloat,
    measurements: TranscriptMeasurementLedger
  ) {
    // Composer geometry is represented by the final spacer row. If its
    // measured height settles while the reader is already at the bottom,
    // keep the latest content stationary; ordinary idle-row changes still
    // preserve their visible block anchor below.
    let pinsBottomSpacerChange =
      previousDistanceFromBottom.map { $0 <= atBottomThreshold } == true
      && bottomSpacerWillChange
    // Following is the reader's intent, set only by their own scrolling
    // (or a restored follow mode) and cleared the moment they scroll up.
    let pinsBottom = gatePinsBottom || pinsBottomSpacerChange || followsLatest
    self.pinsBottom = pinsBottom

    if !pinsBottom,
      let previousDistanceFromBottom,
      !previousLayout.isEmpty
    {
      let visibleRange = previousLayout.visibleRange(
        distanceFromBottom: previousDistanceFromBottom,
        viewportHeight: viewportHeight,
        overscanCount: 0
      ).filter { previousLayout.keys.indices.contains($0) }
      let viewportTop = previousLayout.viewportTop(
        distanceFromBottom: previousDistanceFromBottom,
        viewportHeight: viewportHeight
      )
      // The first intersecting row usually starts above the viewport. Its
      // top is offscreen, so keeping that top stationary lets its own height
      // change push every visible row below it. Anchor on a row that starts
      // inside the viewport instead, which moves the offscreen part of the
      // straddling row rather than the content being read. Among those,
      // prefer a measured row: estimates must not become an anchor when an
      // exact row is available. Only a row taller than the viewport, with
      // no row starting inside it, anchors on its own top.
      let startingRows = visibleRange.filter {
        previousLayout.frame(at: $0).minY >= viewportTop - 0.5
      }
      let anchorIndex =
        startingRows.first { measurements[previousLayout.keys[$0]] != nil }
        ?? startingRows.first
        ?? visibleRange.first
      visibleAnchorKey = anchorIndex.map { previousLayout.keys[$0] }
    } else {
      visibleAnchorKey = nil
    }

    distanceToPreserve =
      if let lockedRestoreDistance {
        lockedRestoreDistance
      } else if pinsBottom {
        0
      } else if initialPositionApplied {
        previousDistanceFromBottom
      } else {
        nil
      }
  }

  /// The bottom distance to apply once `newLayout` exists: the anchored
  /// distance that keeps `visibleAnchorKey` stationary when one is set,
  /// otherwise `distanceToPreserve` itself.
  public func resolvedDistanceFromBottom(
    newLayout: VirtualTranscriptLayout,
    previousLayout: VirtualTranscriptLayout
  ) -> CGFloat? {
    guard let distanceToPreserve else { return nil }
    let anchoredDistance =
      pinsBottom
      ? nil
      : visibleAnchorKey.flatMap { key in
        newLayout.distanceFromBottom(
          preservingAnchor: key,
          previousLayout: previousLayout,
          previousDistanceFromBottom: distanceToPreserve
        )
      }
    return anchoredDistance ?? distanceToPreserve
  }
}

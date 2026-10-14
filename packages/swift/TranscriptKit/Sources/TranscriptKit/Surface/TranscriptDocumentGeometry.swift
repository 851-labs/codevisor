import CoreGraphics
import Foundation

public enum TranscriptDocumentGeometry {
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

public struct TranscriptGeometryRebuildPlan: Equatable, Sendable {
  public let pinsBottom: Bool
  public let visibleAnchorKey: String?
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
    let pinsBottomSpacerChange =
      previousDistanceFromBottom.map { $0 <= atBottomThreshold } == true
      && bottomSpacerWillChange
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

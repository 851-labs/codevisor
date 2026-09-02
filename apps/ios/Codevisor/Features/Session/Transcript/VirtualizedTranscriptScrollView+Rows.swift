import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

// MARK: - Rows

extension VirtualizedTranscriptScrollView {
  /// Adopts a resolved row list. Row bookkeeping lives in `TranscriptRowSet`;
  /// this only sequences the platform side effects (measurement
  /// invalidation, host eviction, document geometry) around it.
  @discardableResult
  func applyRows(
    _ newRows: [TranscriptVirtualRow],
    layoutFingerprintChanged: Bool,
  ) -> Bool {
    let geometryChanged = rowSet.geometryChanged(comparedTo: newRows)
    if geometryChanged || layoutFingerprintChanged {
      TranscriptRowSet.transferActiveHeightIfNeeded(from: rows, to: newRows, ledger: &measurements)
      invalidateChangedMeasurements(
        previousRowsByKey: rowByKey,
        newRows: newRows,
      )
      let previousRowsByKey = rowSet.replaceRows(newRows)
      removeDeletedMountedHosts(previousRowsByKey: previousRowsByKey)
      if layoutFingerprintChanged {
        discardParkedHosts()
      } else {
        evictChangedParkedHosts(previousRowsByKey: previousRowsByKey)
      }
      _ = activateMeasurementCacheIfNeeded()
      installExactSpacerMeasurements()
      // Row-set changes mount and recycle only the affected hosts below.
      // Preserve every other hosting tree so an insertion/removal cannot
      // blank the whole visible transcript for a SwiftUI commit.
      if layoutFingerprintChanged {
        refreshMountedRootViews()
      } else {
        refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
      }
      rebuildDocumentGeometry()
      return true
    } else {
      let previousRowsByKey = rowSet.replaceRows(newRows)
      evictChangedParkedHosts(previousRowsByKey: previousRowsByKey)
      refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
      return false
    }
  }

  @discardableResult
  func applyActiveRows(_ newActiveRows: [TranscriptVirtualRow]) -> Bool {
    switch rowSet.replaceActiveRows(newActiveRows) {
    case let .rebuild(resolvedRows):
      return applyRows(resolvedRows, layoutFingerprintChanged: false)
    case let .inPlace(_, previousRows):
      evictChangedActiveParkedHosts(previousRows: previousRows)
      refreshChangedMountedRootViews(
        previousRowsByKey: Dictionary(
          uniqueKeysWithValues: previousRows.map { ($0.layoutKey, $0) }
        )
      )
      return false
    }
  }

  func evictChangedActiveParkedHosts(
    previousRows: [TranscriptVirtualRow]
  ) {
    let staleKeys = previousRows.compactMap { previous -> String? in
      guard let row = rowByKey[previous.layoutKey],
        previous.content != row.content
          || previous.measurementRevision != row.measurementRevision
      else { return nil }
      return previous.layoutKey
    }
    for key in staleKeys {
      parkedHosts.removeValue(forKey: key)?.detachFromParent()
    }
    parkedHostLRU.removeAll { staleKeys.contains($0) }
  }

  func resolvedRows(
    projectedRows: [TranscriptVirtualRow],
    activeRows: [TranscriptVirtualRow]
  ) -> (rows: [TranscriptVirtualRow], activeRange: Range<Int>?) {
    let resolution = TranscriptRowSet.resolve(projectedRows: projectedRows, activeRows: activeRows)
    return (resolution.rows, resolution.activeRange)
  }

  func reversePrependCount(
    from oldRows: [TranscriptVirtualRow],
    to newRows: [TranscriptVirtualRow],
  ) -> Int? {
    TranscriptRowSet.reversePrependCount(from: oldRows, to: newRows)
  }
}

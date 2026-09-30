import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

// MARK: - Rows

extension VirtualizedTranscriptScrollView: TranscriptSurfaceOwner, TranscriptSurfaceAdapter {
  @discardableResult
  func applyRows(_ rows: [TranscriptVirtualRow], layoutFingerprintChanged: Bool) -> Bool {
    surfaceController.applyRows(rows, layoutChanged: layoutFingerprintChanged, adapter: self)
  }

  @discardableResult
  func applyActiveRows(_ rows: [TranscriptVirtualRow]) -> Bool {
    surfaceController.applyActiveRows(rows, adapter: self)
  }

  func reconcileRetainedHosts(
    previousRowsByKey: [String: TranscriptVirtualRow], layoutChanged: Bool
  ) {
    removeDeletedMountedHosts(previousRowsByKey: previousRowsByKey)
    if layoutChanged {
      parkedHosts.removeAll()
    } else {
      evictChangedParkedHosts(previousRowsByKey: previousRowsByKey)
    }
  }

  func reconcileChangedActiveHosts(previousRows: [TranscriptVirtualRow]) {
    evictChangedActiveParkedHosts(previousRows: previousRows)
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
    parkedHosts.remove(keys: staleKeys)
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

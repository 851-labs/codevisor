import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

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
    retireRemovedMountedHosts(previousRowsByKey: previousRowsByKey)
  }

  func reconcileChangedActiveHosts(previousRows: [TranscriptVirtualRow]) {
  }

  func resolvedRows(
    projectedRows: [TranscriptVirtualRow],
    activeRows: [TranscriptVirtualRow]
  ) -> (rows: [TranscriptVirtualRow], activeRange: Range<Int>?) {
    let resolution = TranscriptRowSet.resolve(projectedRows: projectedRows, activeRows: activeRows)
    return (resolution.rows, resolution.activeRange)
  }
}

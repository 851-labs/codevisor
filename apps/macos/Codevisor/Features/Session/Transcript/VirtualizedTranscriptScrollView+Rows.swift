import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

// MARK: - Rows

extension VirtualizedTranscriptScrollView {
    /// Adopts a resolved row list. Row bookkeeping lives in `TranscriptRowSet`;
    /// this only sequences the platform side effects (measurement
    /// invalidation, host retirement, document geometry) around it.
    @discardableResult
    func applyRows(
        _ newRows: [TranscriptVirtualRow],
        layoutFingerprintChanged: Bool
    ) -> Bool {
        let geometryChanged = rowSet.geometryChanged(comparedTo: newRows)
        if geometryChanged || layoutFingerprintChanged {
            TranscriptRowSet.transferActiveHeightIfNeeded(from: rows, to: newRows, ledger: &measurements)
            invalidateChangedMeasurements(
                previousRowsByKey: rowByKey,
                newRows: newRows
            )
            let previousRowsByKey = rowSet.replaceRows(newRows)
            retireRemovedMountedHosts(previousRowsByKey: previousRowsByKey)
            _ = activateMeasurementCacheIfNeeded()
            for row in newRows {
                if case let .bottomSpacer(height) = row.content {
                    measurements.setExact(height, for: row.layoutKey)
                }
            }
            if layoutFingerprintChanged {
                refreshMountedRootViews()
            } else {
                refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
            }
            rebuildDocumentGeometry()
            return true
        }

        let previousRowsByKey = rowSet.replaceRows(newRows)
        refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
        return false
    }

    @discardableResult
    func applyActiveRows(_ newActiveRows: [TranscriptVirtualRow]) -> Bool {
        switch rowSet.replaceActiveRows(newActiveRows) {
        case let .rebuild(resolvedRows):
            return applyRows(resolvedRows, layoutFingerprintChanged: false)
        case let .inPlace(_, previousRows):
            refreshChangedMountedRootViews(
                previousRowsByKey: Dictionary(
                    uniqueKeysWithValues: previousRows.map { ($0.layoutKey, $0) }
                )
            )
            return false
        }
    }

    func resolvedRows(
        projectedRows: [TranscriptVirtualRow],
        activeRows: [TranscriptVirtualRow]
    ) -> (rows: [TranscriptVirtualRow], activeRange: Range<Int>?) {
        let resolution = TranscriptRowSet.resolve(projectedRows: projectedRows, activeRows: activeRows)
        return (resolution.rows, resolution.activeRange)
    }
}

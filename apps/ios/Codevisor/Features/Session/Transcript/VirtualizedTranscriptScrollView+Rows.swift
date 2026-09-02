import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

// MARK: - Rows

extension VirtualizedTranscriptScrollView {
    @discardableResult
    func applyRows(
        _ newRows: [TranscriptVirtualRow],
        layoutFingerprintChanged: Bool,
    ) -> Bool {
        let geometryChanged =
            rows.count != newRows.count
            || zip(rows, newRows).contains { old, new in
                old.id != new.id
                    || old.estimatedHeight != new.estimatedHeight
                    || old.measurementRevision != new.measurementRevision
            }
        let previousRowsByKey = rowByKey

        if geometryChanged || layoutFingerprintChanged {
            transferActiveHeightIfNeeded(from: rows, to: newRows)
            invalidateChangedMeasurements(
                previousRowsByKey: previousRowsByKey,
                newRows: newRows,
            )
            rows = newRows
            rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
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
            rows = newRows
            rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
            evictChangedParkedHosts(previousRowsByKey: previousRowsByKey)
            refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
            return false
        }
    }

    @discardableResult
    func applyActiveRows(_ newActiveRows: [TranscriptVirtualRow]) -> Bool {
        let resolution = resolvedRows(
            projectedRows: projectedRows,
            activeRows: newActiveRows
        )
        defer {
            activeRows = newActiveRows
            activeRowsRange = resolution.activeRange
        }
        guard let oldRange = activeRowsRange,
            let newRange = resolution.activeRange,
            oldRange.count == newRange.count
        else {
            return applyRows(resolution.rows, layoutFingerprintChanged: false)
        }

        let previousRows = Array(rows[oldRange])
        let replacement = Array(resolution.rows[newRange])
        guard zip(previousRows, replacement).allSatisfy({ $0.layoutKey == $1.layoutKey }) else {
            return applyRows(resolution.rows, layoutFingerprintChanged: false)
        }

        let previousRowsByKey = Dictionary(
            uniqueKeysWithValues: previousRows.map { ($0.layoutKey, $0) }
        )
        rows.replaceSubrange(oldRange, with: replacement)
        for row in replacement {
            rowByKey[row.layoutKey] = row
        }
        evictChangedActiveParkedHosts(previousRows: previousRows)
        refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
        return false
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
        guard
            let activeIndex = projectedRows.firstIndex(where: {
                if case .active = $0.id { true } else { false }
            })
        else { return (projectedRows, nil) }
        guard case let .active(messageID) = projectedRows[activeIndex].id,
            activeRows.first?.id.messageID == messageID
        else { return (projectedRows, activeIndex..<(activeIndex + 1)) }

        var result = projectedRows
        result.replaceSubrange(activeIndex...activeIndex, with: activeRows)
        return (result, activeIndex..<(activeIndex + activeRows.count))
    }

    func reversePrependCount(
        from oldRows: [TranscriptVirtualRow],
        to newRows: [TranscriptVirtualRow],
    ) -> Int? {
        guard !oldRows.isEmpty, newRows.count > oldRows.count else { return nil }
        let insertedCount = newRows.count - oldRows.count
        guard
            zip(oldRows, newRows.dropFirst(insertedCount)).allSatisfy({ old, new in
                old.id == new.id
            })
        else { return nil }
        return insertedCount
    }

    func transferActiveHeightIfNeeded(
        from oldRows: [TranscriptVirtualRow],
        to newRows: [TranscriptVirtualRow],
    ) {
        guard let oldActive = oldRows.first(where: { $0.id.isActiveRow }),
            let activeHeight = measurements[oldActive.layoutKey],
            !newRows.contains(where: { $0.layoutKey == oldActive.layoutKey })
        else { return }
        let oldKeys = Set(oldRows.map(\.layoutKey))
        let insertedSettledRows = newRows.filter {
            $0.id.isCacheableSettledRow && !oldKeys.contains($0.layoutKey)
        }
        guard insertedSettledRows.count == 1,
            let settledActive = insertedSettledRows.first,
            measurements[settledActive.layoutKey] == nil
        else { return }
        measurements.setProvisional(activeHeight, for: settledActive.layoutKey)
    }
}

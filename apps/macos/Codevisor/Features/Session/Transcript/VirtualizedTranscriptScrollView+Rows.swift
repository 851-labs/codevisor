import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

// MARK: - Rows

extension VirtualizedTranscriptScrollView {
    @discardableResult
    func applyRows(
        _ newRows: [TranscriptVirtualRow],
        layoutFingerprintChanged: Bool
    ) -> Bool {
        // Compare only layout identity/estimates. Deep equality here would
        // walk every historical Markdown string whenever the container
        // updates. Mounted hosts receive fresh content below; unmounted rows
        // remain inert until they enter the overscan window.
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
                newRows: newRows
            )
            rows = newRows
            rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
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

        rows = newRows
        rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
        refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
        return false
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
        refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
        return false
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

    func transferActiveHeightIfNeeded(
        from oldRows: [TranscriptVirtualRow],
        to newRows: [TranscriptVirtualRow]
    ) {
        guard let oldActive = oldRows.first(where: { $0.id.isActiveRow }),
            let activeHeight = measurements[oldActive.layoutKey],
            !newRows.contains(where: { $0.layoutKey == oldActive.layoutKey })
        else { return }
        let oldKeys = Set(oldRows.map(\.layoutKey))
        let insertedSettledRows = newRows.filter {
            $0.id.isCacheableSettledRow && !oldKeys.contains($0.layoutKey)
        }
        // One active host can transfer its aggregate height only when it
        // settles into one row. A plan turn intentionally becomes multiple
        // independently measured rows, so assigning the aggregate to any one
        // slice would poison scroll geometry.
        guard insertedSettledRows.count == 1,
            let settledActive = insertedSettledRows.first,
            measurements[settledActive.layoutKey] == nil
        else { return }
        // Provisional, never authoritative: the settled render (auto-collapsed
        // worked section, answer hoisted out of it) differs from the streaming
        // render, so the streaming height positions rows until the settled
        // host measures — but it must not be written into revision-keyed
        // caches where it could outlive this mount as an "exact" measurement.
        measurements.setProvisional(activeHeight, for: settledActive.layoutKey)
    }
}

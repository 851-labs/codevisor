import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

// MARK: - Measurement

extension VirtualizedTranscriptScrollView {
    func invalidateChangedMeasurements(
        previousRowsByKey: [String: TranscriptVirtualRow],
        newRows: [TranscriptVirtualRow]
    ) {
        for row in newRows {
            guard row.id.isCacheableSettledRow,
                let previous = previousRowsByKey[row.layoutKey],
                previous.measurementRevision != row.measurementRevision
            else { continue }
            let key = row.layoutKey
            // The last measured height stays in the ledger as stale layout
            // geometry: a settled row whose content keeps changing (a
            // background subagent streaming into an ended turn bumps this
            // revision on every flush) must never snap back to its flat
            // estimate and let its unclipped content overlap the rows below.
            measurements.markStale(key)
            measurementCache.removeMeasurement(for: key)
            // Mounted content is replaced immediately after invalidation.
            // `installRootView` performs the one required fresh measurement;
            // invalidating here as well used to schedule the same TextKit and
            // hosting-controller work twice for every settled revision.
        }
    }

    /// Switches to the exact measurements for the current text layout. At
    /// most three width/typography variants survive, which handles ordinary
    /// sidebar toggling without allowing per-session memory to grow forever.
    @discardableResult
    func activateMeasurementCacheIfNeeded() -> Bool {
        guard contentView.bounds.width > 0 else { return false }
        let key = SessionMeasurementCacheKey(
            rowWidthHalfPoints: Int((effectiveRowWidth * 2).rounded()),
            layoutFingerprint: layoutFingerprint
        )
        guard key != measurementCache.activeKey else { return false }

        let cached = measurementCache.activate(key)

        // Keep mounted heights as provisional geometry while their independent
        // inner hosts remeasure at the new width. Provisional values are not
        // written into the new width's cache — but they are marked stale, so
        // a host whose height happens to be identical at the new width still
        // commits it into that width's cache instead of being deduped away.
        let provisionalMountedHeights = Dictionary(
            uniqueKeysWithValues: mountedHosts.keys.compactMap { key in
                measurements[key].map { (key, $0) }
            })
        measurements.removeAll(keepingCapacity: true)
        var valid: [String: SessionMeasuredRow] = [:]
        valid.reserveCapacity(cached.count)
        for row in rows {
            let rowKey = row.layoutKey
            guard row.id.isCacheableSettledRow,
                let measurement = cached[rowKey],
                measurement.revision == row.measurementRevision,
                measurement.height > 0
            else { continue }
            valid[rowKey] = measurement
            measurements.setExact(measurement.height, for: rowKey)
        }
        measurementCache.replaceActiveMeasurements(valid)
        for row in rows {
            if case let .bottomSpacer(height) = row.content {
                measurements.setExact(height, for: row.layoutKey)
            }
        }
        for (key, height) in provisionalMountedHeights where measurements[key] == nil {
            measurements.setProvisional(height, for: key)
        }
        // ChatGPT restores the exact height map that produced its saved
        // coordinate before mounting the saved rendered window. Apply it only
        // when the width/typography key still matches; current measurements
        // replace these provisional values as soon as the hosts lay out.
        if let restore = pendingInitialState?.virtualTranscript,
            restore.measurementCacheKey == key
        {
            for (rowKey, height) in restore.rowHeightsByKey where height > 0 {
                guard let row = rowByKey[rowKey] else { continue }
                // A settled row's saved height is applied only when its
                // revision still matches: content can change while the pane
                // is closed (a background subagent streaming into an ended
                // turn), and the snapshot must not restore that stale height
                // as if it were current. Mismatches fall back to the
                // revision-checked cache entry applied above, or the estimate.
                if row.id.isCacheableSettledRow {
                    guard
                        restore.settledRowsByKey[rowKey]?.revision
                            == row.measurementRevision
                    else { continue }
                }
                measurements.setProvisional(height, for: rowKey)
            }
        }
        return true
    }

    /// Rebuilds `virtualLayout` and re-anchors the viewport.
    ///
    /// `changedHeights` is the streaming fast path: when the only difference
    /// from the current layout is a set of committed row heights (row set and
    /// order unchanged — height commits never add or remove rows), the layout
    /// is patched incrementally instead of reconstructed. The full rebuild
    /// re-materializes and re-hashes every row key — O(transcript) string
    /// work on the main thread for what is usually a one-row height change
    /// several times per second per streaming chat.
    func rebuildDocumentGeometry(changedHeights: [String: CGFloat]? = nil) {
        // Capture the viewport before changing document size. A locked restore
        // target wins until the user deliberately scrolls. Once the reader has
        // moved away from the bottom, preserve the first visible row instead
        // of preserving a raw bottom distance: streaming growth below that row
        // must not pull the viewport down with it.
        let previousLayout = virtualLayout
        let previousDistance = initialPositionApplied ? currentDistanceFromBottom() : nil
        // ChatGPT follows the bottom only while the latest turn is live. An
        // idle transcript is static even when its distance is zero, so opening
        // a disclosure preserves the reader's viewport instead of pushing the
        // clicked header offscreen.
        let plan = TranscriptGeometryRebuildPlan(
            previousLayout: previousLayout,
            previousDistanceFromBottom: previousDistance,
            viewportHeight: contentView.bounds.height,
            followsStreamingLatest: followsLatest && rows.contains { $0.id.isActiveRow },
            lockedRestoreDistance: lockedRestoreDistance,
            initialPositionApplied: initialPositionApplied,
            gatePinsBottom: bottomJumpGate.isActive || initialBottomPin.isActive,
            bottomSpacerWillChange: TranscriptDocumentGeometry.bottomSpacerGeometryWillChange(
                from: previousLayout,
                spacerRow: rowByKey[TranscriptVirtualRow.ID.bottomSpacer.layoutKey],
                measurements: measurements
            ),
            atBottomThreshold: Self.atBottomThreshold,
            measurements: measurements
        )
        var initialRestoreRange: Range<Int>?
        applyPositionTransaction {
            virtualLayout =
                TranscriptDocumentGeometry.incrementallyUpdatedLayout(
                    virtualLayout,
                    rowCount: rows.count,
                    changedHeights: changedHeights
                )
                ?? TranscriptDocumentGeometry.layout(
                    rows: rows,
                    measurements: measurements,
                    spacing: Self.rowSpacing
                )
            initialRestoreRange = pendingInitialState?.virtualTranscript?.renderedWindow.flatMap {
                virtualLayout.renderedRange(anchorKey: $0.anchorKey, count: $0.count)
            }

            let width = max(1, contentView.bounds.width)
            transcriptDocumentView.frame = CGRect(
                x: 0,
                y: 0,
                width: width,
                height: paginationHeaderLayout.documentHeight(
                    topPadding: Self.topPadding,
                    rowsHeight: virtualLayout.totalHeight
                )
            )
            positionPaginationLoadingIndicator()
            let firstChangedIndex = changedHeights?.keys.compactMap {
                virtualLayout.indexByKey[$0]
            }.min()
            positionMountedRows(startingAt: firstChangedIndex)
            animatePendingDisclosureCollapse()

            if !initialPositionApplied {
                applyPendingInitialPositionIfPossible()
            } else if let anchor = disclosureViewportAnchor {
                setViewportTop(anchor.viewportTop)
            } else if let resolvedDistance = plan.resolvedDistanceFromBottom(
                newLayout: virtualLayout,
                previousLayout: previousLayout
            ) {
                if lockedRestoreDistance != nil {
                    lockedRestoreDistance = resolvedDistance
                }
                setDistanceFromBottom(resolvedDistance)
            }
            // A delayed bounds notification after this transaction sees the
            // final canonical distance, not the transient pre-compensation one.
            lastDistanceFromBottom = currentDistanceFromBottom()
        }
        // Final geometry and its bottom compensation are now authoritative,
        // but the display server has not committed this run-loop transaction.
        // Lock surviving rows to their captured viewport coordinates here so
        // the intermediate model position can never paint.
        synchronizePendingSendHistoryPositions()
        if initialRestoreRange != nil || changedHeights == nil || mountedCoverageNeedsUpdate() {
            updateMountedRows(rangeOverride: initialRestoreRange)
        }
        updateInitialPresentationReadiness()
        resolveBottomJumpIfPossible()
    }

    func mountedCoverageNeedsUpdate() -> Bool {
        let targetRange = plannedMountedRange()
        let targetKeys = virtualLayout.keys(in: targetRange)
        if targetKeys != virtualWindowHandoff.targetKeys { return true }
        let visibleRange = virtualLayout.visibleRange(
            distanceFromBottom: currentDistanceFromBottom(),
            viewportHeight: contentView.bounds.height,
            overscanCount: 0
        )
        return visibleRange.contains { index in
            guard virtualLayout.keys.indices.contains(index) else { return false }
            return mountedHosts[virtualLayout.keys[index]] == nil
        }
    }

    func invalidateMeasurementForRendererTransition(_ key: String) {
        measurements.markStale(key)
        measurementCache.removeMeasurement(for: key)
    }

    func measuredRootView(for row: TranscriptVirtualRow) -> AnyView {
        guard let rowContent else { return AnyView(EmptyView()) }
        let key = row.layoutKey
        return AnyView(
            rowContent(row)
                .environment(\.streamingTextAnimationFrameClock, streamingTextFrameClock)
                .environment(\.streamMarkdownTextLayoutWidth, effectiveRowWidth)
                .environment(\.transcriptPerformAnchoredDisclosureChange) { [weak self] change in
                    self?.performAnchoredDisclosureChange(in: key, change: change) ?? change()
                }
                .environment(\.transcriptInvalidateRowMeasurement) { [weak self] in
                    self?.mountedHosts[key]?.requestContentMeasurement()
                }
                .onPreferenceChange(AttachmentGeometryReadinessPreferenceKey.self) {
                    [weak self] unresolvedCount in
                    self?.attachmentGeometryReadinessDidChange(
                        unresolvedCount == 0,
                        for: key
                    )
                }
                // The hosting view's measured height is rounded up to keep
                // row geometry stable. Pin the SwiftUI root to the top so any
                // sub-point rounding slack stays below the message instead of
                // recentering it when a disclosure changes the row height.
                .frame(width: effectiveRowWidth, alignment: .topLeading)
                .id(key)
        )
    }

    func attachmentGeometryReadinessDidChange(_ ready: Bool, for key: String) {
        guard let host = mountedHosts[key], host.setAttachmentGeometryReady(ready) else {
            return
        }
        promoteTargetWindowAndRetireIfReady()
        updateInitialPresentationReadiness()
    }

    func recordMeasuredHeight(_ rawHeight: CGFloat, for key: String) {
        let height = max(1, rawHeight.rounded(.up))
        guard rowByKey[key] != nil else { return }
        // A stale ledger key must reach the commit even when the reported
        // height is unchanged — that commit is what clears the staleness and
        // rewrites the row's revision-keyed cache entries.
        let needsCommit =
            pendingMeasuredHeights[key].map { abs($0 - height) > 0.5 }
            ?? measurements.needsCommit(height, for: key)
        guard needsCommit else {
            // Cached settled rows can report the exact height already in the
            // ledger. Fresh AppKit layout still completes presentation gates.
            promoteTargetWindowAndRetireIfReady()
            updateInitialPresentationReadiness()
            resolveBottomJumpIfPossible()
            startPendingSendAnimationIfPossible()
            return
        }
        pendingMeasuredHeights[key] = height

        // A mounted transcript commits all height changes on its native display
        // clock. Content, following offsets, document size, and bottom
        // compensation therefore become one physical-frame transaction.
        if presentationDisplayLink != nil, !inLiveResize {
            requestDisplayFrame()
            return
        }
        guard measurementCommitTask == nil else { return }
        measurementCommitTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.commitPendingMeasurements()
        }
    }

    func commitPendingMeasurements() {
        measurementCommitTask = nil
        let pending = pendingMeasuredHeights
        pendingMeasuredHeights.removeAll(keepingCapacity: true)
        var committedHeights: [String: CGFloat] = [:]
        for (key, height) in pending {
            guard rowByKey[key] != nil,
                measurements.needsCommit(height, for: key)
            else { continue }
            if storeMeasuredHeight(height, for: key) {
                committedHeights[key] = height
            }
        }
        if !committedHeights.isEmpty {
            // Height-only commits qualify for the incremental layout patch;
            // row-set changes always come through `configure`'s full rebuild.
            rebuildDocumentGeometry(changedHeights: committedHeights)
        }
        promoteTargetWindowAndRetireIfReady()
        updateInitialPresentationReadiness()
        resolveBottomJumpIfPossible()
        startPendingSendAnimationIfPossible()
    }

    /// Commits one measurement into the ledger and the revision-keyed caches.
    /// Returns whether the height actually moved (geometry must rebuild); a
    /// same-height commit still refreshes caches for the row's new revision.
    @discardableResult
    func storeMeasuredHeight(_ height: CGFloat, for key: String) -> Bool {
        let heightChanged = measurements.commit(height, for: key)
        if let row = rowByKey[key], row.id.isCacheableSettledRow {
            let measurement = SessionMeasuredRow(
                height: height,
                revision: row.measurementRevision
            )
            measurementCache.store(measurement, for: key)
        }
        return heightChanged
    }
}

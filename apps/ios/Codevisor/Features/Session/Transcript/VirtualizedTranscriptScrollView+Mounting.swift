import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

// MARK: - Mounting

extension VirtualizedTranscriptScrollView {
    func discardParkedHosts() {
        for host in parkedHosts.values {
            host.detachFromParent()
        }
        parkedHosts.removeAll(keepingCapacity: false)
        parkedHostLRU.removeAll(keepingCapacity: false)
    }

    func plannedMountedRange(scrollDelta: CGFloat = 0) -> Range<Int> {
        windowPlanner.plannedRange(
            layout: virtualLayout,
            distanceFromBottom: currentDistanceFromBottom(),
            viewportHeight: viewportHeight,
            scrollDelta: scrollDelta,
            isInitialPresentationReady: initialPresentationGate.isReady,
            currentTargetKeys: virtualWindowHandoff.targetKeys
        )
    }

    func updateMountedRows(rangeOverride: Range<Int>? = nil) {
        guard initialPositionApplied || viewportHeight > 0,
            let hostingParent
        else { return }
        virtualWindowHandoff.retainOnlyValidKeys { rowByKey[$0] != nil }
        let scrollDelta = rangeOverride == nil ? pendingWindowScrollDelta : 0
        pendingWindowScrollDelta = 0
        let targetRange: Range<Int>
        if let rangeOverride {
            targetRange = rangeOverride
        } else {
            targetRange = plannedMountedRange(scrollDelta: scrollDelta)
        }
        let visibleRange = virtualLayout.visibleRange(
            distanceFromBottom: currentDistanceFromBottom(),
            viewportHeight: viewportHeight,
            overscanCount: 0,
        )
        virtualWindowHandoff.setTarget(
            TranscriptWindowPlanner.targetKeys(
                layout: virtualLayout,
                targetRange: targetRange,
                visibleRange: visibleRange
            )
        )

        let mountPlan = virtualWindowPolicy.mountPlan(
            targetRange: targetRange,
            visibleRange: visibleRange,
            scrollDelta: scrollDelta,
        )
        let mountStarted = CACurrentMediaTime()
        for index in mountPlan.visibleIndices {
            mountRow(
                at: index,
                parent: hostingParent,
                requiresImmediatePresentation: true
            )
        }
        assert(
            mountPlan.visibleIndices.allSatisfy { index in
                guard virtualLayout.keys.indices.contains(index) else { return false }
                return mountedHosts[virtualLayout.keys[index]] != nil
            },
            "Loaded transcript viewport must be fully mounted"
        )

        for index in mountPlan.runwayIndices {
            guard virtualLayout.keys.indices.contains(index) else { continue }
            let key = virtualLayout.keys[index]
            guard mountedHosts[key] == nil else { continue }
            guard presentationDisplayLink == nil || remainingMountsThisFrame > 0 else { break }
            if presentationDisplayLink != nil,
                CACurrentMediaTime() - mountStarted >= mountWorkBudget
            {
                break
            }
            if mountRow(
                at: index,
                parent: hostingParent,
                requiresImmediatePresentation: false
            ), presentationDisplayLink != nil {
                remainingMountsThisFrame -= 1
            }
        }
        removeMountedHosts(excluding: virtualWindowHandoff.retainedKeys)
        promoteTargetWindowIfReady()
        if presentationDisplayLink != nil,
            virtualWindowHandoff.targetKeys.contains(where: { mountedHosts[$0] == nil })
        {
            requestMountedRowsUpdate()
        }
        synchronizePendingSendHistoryPositions()
        synchronizeSendAssistantVisibility()
    }

    @discardableResult
    func mountRow(
        at index: Int,
        parent: UIViewController,
        requiresImmediatePresentation: Bool
    ) -> Bool {
        guard virtualLayout.keys.indices.contains(index) else { return false }
        let key = virtualLayout.keys[index]
        if let host = mountedHosts[key] {
            if requiresImmediatePresentation, !host.isPresentationReady {
                host.prepareForImmediatePresentation()
            }
            return false
        }
        guard let row = rowByKey[key] else { return false }

        let host = takeParkedHost(for: key) ?? TranscriptRowHost(parent: parent)
        host.prepareForMountedRow()
        sendHistoryHoldMounts.removeValue(forKey: key)
        sendAssistantHoldMounts.removeValue(forKey: key)
        host.onMeasuredHeight = { [weak self] measurement in
            self?.recordMeasuredHeight(measurement)
        }
        canvasView.addSubview(host)
        mountedHosts[key] = host
        position(host: host, at: index)
        host.syncContentWidth()
        if defersActivePlaceholderPresentation(for: row) {
            deferredActivePlaceholderKey = key
            host.install(
                row: row,
                rootView: AnyView(Color.clear.frame(height: row.estimatedHeight)),
                force: true
            )
            return true
        }
        host.install(
            row: row,
            rootView: measuredRootView(for: row),
            force: host.representedRow == nil,
        )
        if requiresImmediatePresentation {
            host.prepareForImmediatePresentation()
        }
        synchronizePendingSendTargetVisibility()
        synchronizePendingSendHistoryPositions()
        synchronizeSendAssistantVisibility()
        return true
    }

    /// Whether `row` is the aggregate active placeholder that the pending
    /// first active projection is about to replace, while the document is
    /// still hidden behind the initial presentation gate.
    func defersActivePlaceholderPresentation(for row: TranscriptVirtualRow) -> Bool {
        guard case .active = row.id else { return false }
        return isAwaitingFirstActiveProjection && !initialPresentationGate.isReady
    }

    /// Gives a deferred placeholder its real content once the first active
    /// projection has published but left the aggregate row in place (an item
    /// that projects to no precise rows yet).
    func presentDeferredActivePlaceholderIfNeeded() {
        guard let key = deferredActivePlaceholderKey, !isAwaitingFirstActiveProjection else { return }
        deferredActivePlaceholderKey = nil
        guard let row = rowByKey[key], let host = mountedHosts[key] else { return }
        host.install(row: row, rootView: measuredRootView(for: row), force: true)
        host.resetReportedContentHeight()
        host.prepareForImmediatePresentation()
    }

    func promoteTargetWindowIfReady() {
        guard
            virtualWindowHandoff.promoteIfReady({ key in
                TranscriptMountedWindowReadiness.isPromotable(
                    key: key,
                    measurements: measurements,
                    hasPendingMeasurement: pendingMeasurements[key] != nil,
                    host: mountedHosts[key]
                )
            })
        else { return }
        removeMountedHosts(excluding: virtualWindowHandoff.retainedKeys)
    }

    func removeMountedHosts(excluding retainedKeys: Set<String>) {
        let obsoleteKeys = mountedHosts.keys.filter { !retainedKeys.contains($0) }
        removeMountedHosts(withKeys: obsoleteKeys)
    }

    /// Deleted rows must leave the canvas in the same transaction that removes
    /// them from geometry. The window handoff drops invalid keys before its
    /// normal cleanup, so it cannot retire these orphaned views afterward.
    func removeDeletedMountedHosts(
        previousRowsByKey: [String: TranscriptVirtualRow]
    ) {
        let deletedMountedKeys = previousRowsByKey.keys.filter {
            rowByKey[$0] == nil && mountedHosts[$0] != nil
        }
        removeMountedHosts(withKeys: deletedMountedKeys)
    }

    func removeMountedHosts(withKeys obsoleteKeys: [String]) {
        for key in obsoleteKeys {
            guard let host = mountedHosts.removeValue(forKey: key) else { continue }
            host.removeFromSuperview()
            park(host, for: key)
        }
        assert(mountedHosts.keys.allSatisfy { rowByKey[$0] != nil })
    }

    func park(_ host: TranscriptRowHost, for key: String) {
        guard rowByKey[key] != nil else {
            host.detachFromParent()
            return
        }
        parkedHosts[key]?.detachFromParent()
        parkedHosts[key] = host
        parkedHostLRU.removeAll { $0 == key }
        parkedHostLRU.append(key)
        while parkedHostLRU.count > Self.maxParkedHostCount {
            let evicted = parkedHostLRU.removeFirst()
            parkedHosts.removeValue(forKey: evicted)?.detachFromParent()
        }
    }

    func takeParkedHost(for key: String) -> TranscriptRowHost? {
        guard let host = parkedHosts.removeValue(forKey: key) else { return nil }
        parkedHostLRU.removeAll { $0 == key }
        return host
    }

    func evictChangedParkedHosts(
        previousRowsByKey: [String: TranscriptVirtualRow],
    ) {
        let staleKeys = parkedHostLRU.filter { key in
            guard let row = rowByKey[key] else { return true }
            return previousRowsByKey[key]?.content != row.content
                || previousRowsByKey[key]?.measurementRevision != row.measurementRevision
        }
        for key in staleKeys {
            parkedHosts.removeValue(forKey: key)?.detachFromParent()
        }
        parkedHostLRU.removeAll { staleKeys.contains($0) }
    }

    func refreshMountedRootViews() {
        for (key, host) in mountedHosts {
            guard let row = rowByKey[key] else { continue }
            host.install(row: row, rootView: measuredRootView(for: row), force: true)
        }
    }

    func refreshChangedMountedRootViews(
        previousRowsByKey: [String: TranscriptVirtualRow],
    ) {
        for (key, host) in mountedHosts {
            guard let row = rowByKey[key], let previous = previousRowsByKey[key],
                previous.content != row.content
                    || previous.measurementRevision != row.measurementRevision
            else { continue }
            host.install(row: row, rootView: measuredRootView(for: row), force: true)
        }
    }

    func positionMountedRows() {
        for (key, host) in mountedHosts {
            guard let index = virtualLayout.indexByKey[key] else { continue }
            position(host: host, at: index)
        }
    }

    func position(host: TranscriptRowHost, at index: Int) {
        guard virtualLayout.heights.indices.contains(index) else { return }
        let viewportWidth = max(1, bounds.width)
        let availableWidth = max(1, viewportWidth - Self.horizontalPadding * 2)
        let rowWidth = min(Self.maxRowWidth, availableWidth)
        let rowX = max(Self.horizontalPadding, (viewportWidth - rowWidth) / 2)
        let nextFrame = CGRect(
            x: rowX,
            y: paginationHeaderLayout.rowOrigin(
                topPadding: Self.topPadding,
                rowOffset: virtualLayout.topOffsets[index]
            ),
            width: rowWidth,
            height: virtualLayout.heights[index],
        )
        if host.frame != nextFrame {
            host.frame = nextFrame
        }
        host.syncContentWidth()
    }
}

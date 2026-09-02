import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

// MARK: - Mounting

extension VirtualizedTranscriptScrollView {
    func plannedMountedRange(scrollDelta: CGFloat = 0) -> Range<Int> {
        windowPlanner.plannedRange(
            layout: virtualLayout,
            distanceFromBottom: currentDistanceFromBottom(),
            viewportHeight: contentView.bounds.height,
            scrollDelta: scrollDelta,
            isInitialPresentationReady: initialPresentationGate.isReady,
            currentTargetKeys: virtualWindowHandoff.targetKeys
        )
    }

    func updateMountedRows(rangeOverride: Range<Int>? = nil) {
        guard initialPositionApplied || contentView.bounds.height > 0 else { return }
        guard !isUpdatingMountedRows else {
            deferMountedRowsUpdateUntilLayoutCompletes(rangeOverride: rangeOverride)
            return
        }
        isUpdatingMountedRows = true
        defer { isUpdatingMountedRows = false }
        let reconciliation = reconcileVirtualWindow(rangeOverride: rangeOverride)
        let mountPlan = reconciliation.mountPlan
        let usesFrameBudget = presentationDisplayLink != nil && !inLiveResize
        let mountStarted = CACurrentMediaTime()
        // Loaded viewport rows are never optional. Mount and flush all of them
        // before this native scroll frame can be presented; applying the frame
        // budget here is what exposed transparent document space at speed.
        for index in mountPlan.visibleIndices {
            mountRow(at: index, requiresImmediatePresentation: true)
        }
        assert(
            mountPlan.visibleIndices.allSatisfy { index in
                guard virtualLayout.keys.indices.contains(index) else { return false }
                return mountedHosts[virtualLayout.keys[index]] != nil
            },
            "Loaded transcript viewport must be fully mounted"
        )

        // Complete the closest directional runway rows one at a time. Mounting
        // a collection of hosts before laying any of them out consumed the
        // frame budget on root installation and left the nearest rows unable
        // to present when momentum carried them into the viewport.
        prepareRunwayRowsEndToEnd(
            at: mountPlan.runwayIndices,
            workStartedAt: mountStarted,
            usesFrameBudget: usesFrameBudget
        )
        // Rows from an abandoned intermediate target are neither the last
        // complete window nor part of the window currently being prepared.
        if reconciliation.targetChanged {
            retireMountedHosts(excluding: virtualWindowHandoff.retainedKeys)
        }
        promoteTargetWindowAndRetireIfReady()
        let needsRunwayPreparation =
            canPrepareRunwayRows
            && virtualWindowHandoff.targetKeys.contains { key in
                mountedHosts[key]?.needsRunwayPreparation == true
            }
        if usesFrameBudget,
            virtualWindowHandoff.targetKeys.contains(where: { mountedHosts[$0] == nil })
                || needsRunwayPreparation
        {
            requestMountedRowsUpdate()
        }
        synchronizePendingSendHistoryPositions()
        synchronizeSendAssistantVisibility()
    }

    func reconcileVirtualWindow(
        rangeOverride: Range<Int>?
    ) -> (mountPlan: TranscriptVirtualWindowMountPlan, targetChanged: Bool) {
        virtualWindowHandoff.retainOnlyValidKeys { rowByKey[$0] != nil }
        let observedScrollDelta = rangeOverride == nil ? pendingWindowScrollDelta : 0
        pendingWindowScrollDelta = 0
        let projectedScrollDelta =
            rangeOverride == nil
            ? runwayMotion.projectedDelta(
                timestamp: CACurrentMediaTime(),
                maximumDistance: contentView.bounds.height * 3
            )
            : 0
        let scrollDelta =
            abs(projectedScrollDelta) > abs(observedScrollDelta)
            ? projectedScrollDelta
            : observedScrollDelta
        let targetRange = rangeOverride ?? plannedMountedRange(scrollDelta: scrollDelta)
        let visibleRange = virtualLayout.visibleRange(
            distanceFromBottom: currentDistanceFromBottom(),
            viewportHeight: contentView.bounds.height,
            overscanCount: 0
        )
        let targetKeys = TranscriptWindowPlanner.targetKeys(
            layout: virtualLayout,
            targetRange: targetRange,
            visibleRange: visibleRange
        )
        let targetChanged = targetKeys != virtualWindowHandoff.targetKeys
        if targetChanged {
            virtualWindowHandoff.setTarget(targetKeys)
        }
        return (
            virtualWindowPolicy.mountPlan(
                targetRange: targetRange,
                visibleRange: visibleRange,
                scrollDelta: scrollDelta
            ),
            targetChanged
        )
    }

    /// A mounted runway is useful only after its SwiftUI/AppKit subtree has
    /// completed first layout. Directional rows are prepared on display-link
    /// frames even during live scrolling, but both the count and elapsed work
    /// remain bounded. The viewport keeps its synchronous no-blank fallback.
    func prepareRunwayRowsEndToEnd(
        at indices: [Int],
        workStartedAt: CFTimeInterval,
        usesFrameBudget: Bool
    ) {
        for index in indices {
            if usesFrameBudget,
                remainingMountsThisFrame == 0,
                remainingRunwayPreparationsThisFrame == 0
            {
                break
            }
            guard virtualLayout.keys.indices.contains(index) else { continue }
            if usesFrameBudget,
                CACurrentMediaTime() - workStartedAt >= mountWorkBudget
            {
                break
            }
            let key = virtualLayout.keys[index]
            if mountedHosts[key] == nil {
                guard !usesFrameBudget || remainingMountsThisFrame > 0 else {
                    continue
                }
                if mountRow(at: index, requiresImmediatePresentation: false), usesFrameBudget {
                    remainingMountsThisFrame -= 1
                }
            }
            guard let host = mountedHosts[key], host.needsRunwayPreparation else { continue }
            guard canPrepareRunwayRows else { continue }
            guard !usesFrameBudget || remainingRunwayPreparationsThisFrame > 0 else {
                continue
            }
            host.prepareForImmediatePresentation()
            if usesFrameBudget { remainingRunwayPreparationsThisFrame -= 1 }
        }
    }

    @discardableResult
    func mountRow(
        at index: Int,
        requiresImmediatePresentation: Bool
    ) -> Bool {
        guard virtualLayout.keys.indices.contains(index) else { return false }
        let key = virtualLayout.keys[index]
        if let host = mountedHosts[key] {
            // A deferred placeholder keeps its clear root until its rows
            // publish; forcing a layout would only measure that empty root.
            if requiresImmediatePresentation, !host.isPresentationReady,
                key != deferredActivePlaceholderKey
            {
                host.prepareForImmediatePresentation()
            }
            return false
        }
        guard let row = rowByKey[key] else { return false }
        if usesNativeMarkdownHost(for: row) {
            return mountMarkdownRow(
                row,
                at: index,
                requiresImmediatePresentation: requiresImmediatePresentation
            )
        }

        let host: TranscriptRowHost
        if recycledHosts.isEmpty, retiringHosts.isEmpty {
            host = TranscriptRowHost(frame: .zero)
        } else {
            host =
                if let retiring = retiringHosts.popLast() {
                    retiring
                } else {
                    recycledHosts.removeLast()
                }
        }
        host.prepareForMountedRow()
        sendHistoryHoldMounts.removeValue(forKey: key)
        sendAssistantHoldMounts.removeValue(forKey: key)
        host.onHeightChange = { [weak self] height in
            self?.recordMeasuredHeight(height, for: key)
        }
        transcriptDocumentView.addSubview(host)
        mountedHosts[key] = host
        // Position and push the content width before assigning the root view.
        // Otherwise its first TextKit measurement can race the 1pt placeholder.
        position(host: host, at: index)
        host.syncContentWidth()
        if defersActivePlaceholderPresentation(for: row) {
            deferredActivePlaceholderKey = key
            host.installRootView(
                AnyView(Color.clear.frame(height: row.estimatedHeight)),
                knownHeight: row.estimatedHeight
            )
            return true
        }
        let rootView = measuredRootView(for: row)
        let knownHeight: CGFloat? =
            if row.id.isCacheableSettledRow,
                let measuredHeight = measurements[key],
                !measurements.isStale(key)
            {
                measuredHeight
            } else {
                nil
            }
        host.installRootView(rootView, knownHeight: knownHeight)
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
        guard rowByKey[key] != nil, mountedHosts[key] != nil else { return }
        replaceMountedHost(for: key)
    }

    func usesNativeMarkdownHost(for row: TranscriptVirtualRow) -> Bool {
        guard case let .markdownChunk(chunk) = row.content else { return false }
        return chunk.lifecycle == .settled
    }

    func mountMarkdownRow(
        _ row: TranscriptVirtualRow,
        at index: Int,
        requiresImmediatePresentation: Bool
    ) -> Bool {
        guard case let .markdownChunk(chunk) = row.content else { return false }
        let key = row.layoutKey
        let host: TranscriptMarkdownRowHost
        if let prepared = markdownHostCache.take(for: key) {
            host = prepared
        } else if let recycled = recycledMarkdownHosts.popLast() {
            host = recycled
        } else {
            host = TranscriptMarkdownRowHost(frame: .zero)
        }

        host.prepareForMountedRow()
        sendHistoryHoldMounts.removeValue(forKey: key)
        sendAssistantHoldMounts.removeValue(forKey: key)
        host.onHeightChange = { [weak self] height in
            self?.recordMeasuredHeight(height, for: key)
        }
        transcriptDocumentView.addSubview(host)
        mountedHosts[key] = host
        position(host: host, at: index)
        let knownHeight: CGFloat? =
            if let measuredHeight = measurements[key], !measurements.isStale(key) {
                measuredHeight
            } else {
                nil
            }
        host.setContent(
            chunk,
            streamID: key,
            style: markdownRowStyle,
            knownHeight: knownHeight
        )
        if requiresImmediatePresentation, !host.isPresentationReady {
            host.prepareForImmediatePresentation()
        }
        synchronizePendingSendHistoryPositions()
        synchronizeSendAssistantVisibility()
        return true
    }

    func promoteTargetWindowIfReady() -> Bool {
        guard virtualWindowHandoff.presentedKeys != virtualWindowHandoff.targetKeys else {
            return false
        }
        return virtualWindowHandoff.promoteIfReady { key in
            TranscriptMountedWindowReadiness.isPromotable(
                key: key,
                measurements: measurements,
                hasPendingMeasurement: pendingMeasuredHeights[key] != nil,
                host: mountedHosts[key]
            )
        }
    }

    @discardableResult
    func promoteTargetWindowAndRetireIfReady() -> Bool {
        let promoted = promoteTargetWindowIfReady()
        guard promoted else { return false }
        retireMountedHosts(excluding: virtualWindowHandoff.retainedKeys)
        return true
    }

    func retireMountedHosts(excluding retainedKeys: Set<String>) {
        let obsoleteKeys = mountedHosts.keys.filter { !retainedKeys.contains($0) }
        retireMountedHosts(withKeys: obsoleteKeys)
    }

    /// Row-set removals are authoritative and cannot wait for the virtual
    /// window handoff. The handoff prunes invalid keys before its ordinary
    /// retirement pass, so leaving these hosts mounted would keep their pixels
    /// visible after disclosure geometry closes underneath them.
    func retireRemovedMountedHosts(
        previousRowsByKey: [String: TranscriptVirtualRow]
    ) {
        let removedMountedKeys = previousRowsByKey.keys.filter {
            rowByKey[$0] == nil && mountedHosts[$0] != nil
        }
        let automaticSections = automaticallyCollapsedWorkedSections(
            previousRowsByKey: previousRowsByKey
        )
        let automaticGroups = Dictionary(grouping: removedMountedKeys) { key in
            previousRowsByKey[key]?.workedSection?.identity
        }.compactMap { identity, keys -> [String]? in
            guard let identity, automaticSections.contains(identity),
                keys.contains(where: { key in
                    previousRowsByKey[key]?.workedSection?.role == .content
                })
            else { return nil }
            return keys.filter {
                previousRowsByKey[$0]?.workedSection?.role == .content
            }
        }.filter(canAnimateDisclosureCollapse)
        let animatedKeys = Set(automaticGroups.flatMap { $0 })

        if !animatedKeys.isEmpty {
            beginDisclosureViewportAnchor()
            pendingDisclosureCollapseOrigins = Dictionary(
                uniqueKeysWithValues: mountedHosts.compactMap { key, host in
                    guard !animatedKeys.contains(key) else { return nil }
                    return (key, presentedOriginY(for: host))
                }
            )
            for keys in automaticGroups {
                startAutomaticDisclosureCollapse(keys: keys)
            }
        }
        retireMountedHosts(withKeys: removedMountedKeys.filter { !animatedKeys.contains($0) })
    }

    func retireMountedHosts(withKeys obsoleteKeys: [String]) {
        guard !obsoleteKeys.isEmpty else { return }
        for key in obsoleteKeys {
            guard let host = mountedHosts.removeValue(forKey: key) else { continue }
            host.removeFromSuperviewWithoutNeedingDisplay()
            storeDetachedHost(host, for: key)
        }
        assert(mountedHosts.keys.allSatisfy { rowByKey[$0] != nil })
        if !retiringHosts.isEmpty { requestDisplayFrame() }
    }

    func storeDetachedHost(_ host: TranscriptMountedRowHost, for key: String) {
        host.onHeightChange = nil
        host.layer?.removeAnimation(forKey: Self.disclosureExitAnimationKey)
        host.layer?.removeAnimation(forKey: Self.disclosureCollapseAnimationKey)
        host.layer?.opacity = 1
        host.setAccessibilityHidden(false)
        if let markdownHost = host as? TranscriptMarkdownRowHost {
            let evicted = markdownHostCache.insert(
                markdownHost,
                for: key,
                height: host.frame.height,
                maximumTotalHeight: max(1, contentView.bounds.height * 12)
            )
            for host in evicted {
                if recycledMarkdownHosts.count < 8 {
                    recycledMarkdownHosts.append(host)
                }
            }
        } else if let hosted = host as? TranscriptRowHost {
            retiringHosts.append(hosted)
        }
    }

    func drainRetiringHosts(limit: Int) {
        for _ in 0..<max(0, limit) {
            guard let host = retiringHosts.popLast() else { return }
            if recycledHosts.count < 8 {
                recycledHosts.append(host)
            }
            // Once the warm pool is full, dropping this final reference tears
            // the host down here, outside live scrolling. The per-frame limit
            // prevents a large abandoned window from becoming one idle hitch.
        }
    }

    func refreshMountedRootViews() {
        refreshMountedHosts(previousRowsByKey: nil)
    }

    func refreshChangedMountedRootViews(
        previousRowsByKey: [String: TranscriptVirtualRow]
    ) {
        refreshMountedHosts(previousRowsByKey: previousRowsByKey)
    }

    func refreshMountedHosts(
        previousRowsByKey: [String: TranscriptVirtualRow]?
    ) {
        var replacementKeys: [String] = []
        for (key, host) in mountedHosts {
            guard let row = rowByKey[key] else { continue }
            // The deferred placeholder is refreshed by
            // `presentDeferredActivePlaceholderIfNeeded` once its rows publish.
            // Re-installing the aggregate root here would hand the late
            // presentation path the full item to lay out before the reveal.
            if key == deferredActivePlaceholderKey { continue }
            if let previousRowsByKey {
                guard let previous = previousRowsByKey[key],
                    previous.content != row.content
                        || previous.measurementRevision != row.measurementRevision
                else { continue }
            }

            let wantsNativeMarkdown = usesNativeMarkdownHost(for: row)
            let isNativeMarkdown = host is TranscriptMarkdownRowHost
            let preservesLiveMarkdownHost = preservesLiveMarkdownHost(
                host: host,
                previous: previousRowsByKey?[key],
                current: row
            )
            guard wantsNativeMarkdown == isNativeMarkdown || preservesLiveMarkdownHost else {
                invalidateMeasurementForRendererTransition(key)
                replacementKeys.append(key)
                continue
            }

            if let markdownHost = host as? TranscriptMarkdownRowHost,
                case let .markdownChunk(chunk) = row.content
            {
                let knownHeight: CGFloat? =
                    if let height = measurements[key], !measurements.isStale(key) {
                        height
                    } else {
                        nil
                    }
                markdownHost.setContent(
                    chunk,
                    streamID: key,
                    style: markdownRowStyle,
                    knownHeight: knownHeight
                )
            } else if let hosted = host as? TranscriptRowHost {
                hosted.rootView = measuredRootView(for: row)
            }
        }

        for key in replacementKeys {
            replaceMountedHost(for: key)
        }
    }

    /// A response becoming settled is a data transition, not a new visual
    /// stream. Keep its already-mounted SwiftUI/TextKit host until it naturally
    /// leaves the virtual window; a later settled remount can use the cheaper
    /// native settled host without interrupting the final entrance animation.
    func preservesLiveMarkdownHost(
        host: TranscriptMountedRowHost,
        previous: TranscriptVirtualRow?,
        current: TranscriptVirtualRow
    ) -> Bool {
        guard host is TranscriptRowHost,
            case let .markdownChunk(previousChunk) = previous?.content,
            case let .markdownChunk(currentChunk) = current.content
        else { return false }
        return previousChunk.lifecycle == .receiving
            && currentChunk.lifecycle == .settled
    }

    func replaceMountedHost(for key: String) {
        guard let host = mountedHosts.removeValue(forKey: key),
            let index = virtualLayout.indexByKey[key]
        else { return }
        let visibleDocumentRect = NSRect(
            x: 0,
            y: contentView.bounds.minY,
            width: transcriptDocumentView.bounds.width,
            height: contentView.bounds.height
        )
        let requiresImmediatePresentation = host.frame.intersects(visibleDocumentRect)
        host.removeFromSuperviewWithoutNeedingDisplay()
        storeDetachedHost(host, for: key)
        _ = mountRow(
            at: index,
            requiresImmediatePresentation: requiresImmediatePresentation
        )
    }

    func positionMountedRows(startingAt firstChangedIndex: Int? = nil) {
        for (key, host) in mountedHosts {
            guard let index = virtualLayout.indexByKey[key] else { continue }
            if let firstChangedIndex, index < firstChangedIndex { continue }
            let frame = rowFrame(at: index)
            guard host.frame.size != frame.size || host.frame.origin != frame.origin else {
                continue
            }
            position(host: host, frame: frame)
        }
    }

    func position(host: TranscriptMountedRowHost, at index: Int) {
        position(host: host, frame: rowFrame(at: index))
    }

    func rowFrame(at index: Int) -> CGRect {
        let viewportWidth = max(1, contentView.bounds.width)
        let availableWidth = max(1, viewportWidth - Self.horizontalPadding * 2)
        let rowWidth = min(Self.maxRowWidth, availableWidth)
        let rowX = max(Self.horizontalPadding, (viewportWidth - rowWidth) / 2)
        return CGRect(
            x: rowX,
            y: paginationHeaderLayout.rowOrigin(
                topPadding: Self.topPadding,
                rowOffset: virtualLayout.topOffsets[index]
            ),
            width: rowWidth,
            height: virtualLayout.heights[index]
        )
    }

    func position(host: TranscriptMountedRowHost, frame: CGRect) {
        // Height commits move every later row but do not change those rows'
        // content geometry. Assigning the complete frame for a y-only move
        // needlessly invalidates AppKit/SwiftUI layout; update size and origin
        // independently so already-laid-out hosts remain clean.
        if host.frame.size != frame.size {
            host.setFrameSize(frame.size)
        }
        if host.frame.origin != frame.origin {
            host.setFrameOrigin(frame.origin)
        }
    }
}

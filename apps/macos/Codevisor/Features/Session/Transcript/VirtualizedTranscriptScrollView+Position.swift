import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

// MARK: - Position

extension VirtualizedTranscriptScrollView {
    func persistViewport() {
        guard !isDetaching else {
            republishLastStableScrollState()
            return
        }
        // NSViewRepresentable calls this while the clip view still owns its
        // live bounds. Capture the final compensated coordinate, including
        // measurements learned since the user's last wheel event, before
        // AppKit begins teardown.
        emitViewportSnapshot()
    }

    func applyPendingInitialPositionIfPossible() {
        guard !initialPositionApplied, contentView.bounds.height > 0 else { return }

        let shouldPublishInitialPosition =
            lastStableScrollState == nil
            || (pendingInitialState?.isAtBottom == true && followsLatest)

        let restoredRange = pendingInitialState?.virtualTranscript?.renderedWindow.flatMap {
            virtualLayout.renderedRange(anchorKey: $0.anchorKey, count: $0.count)
        }
        // Mount the same neighborhood that was present when the coordinate was
        // saved. Otherwise estimates can select a different part of the thread
        // and the first measurement pass starts from the wrong content.
        updateMountedRows(rangeOverride: restoredRange)

        if let state = pendingInitialState, !state.isAtBottom {
            if let restoredTop = restoredViewportTop(from: state) {
                setViewportTop(restoredTop)
                // Subsequent asynchronous measurements preserve the restored
                // anchor from this resolved coordinate, not the stale fallback
                // distance that preceded it.
                lockedRestoreDistance = currentDistanceFromBottom()
            } else {
                let maximumDistance = max(
                    0,
                    transcriptDocumentView.frame.height - contentView.bounds.height
                )
                if state.distanceFromBottom > maximumDistance + 0.5, hasOlderHistory {
                    setViewportTop(0)
                    checkForHistoryPrefetch(force: true)
                    return
                }
                setDistanceFromBottom(state.distanceFromBottom)
            }
            publishBottomState(currentDistanceFromBottom() <= Self.atBottomThreshold)
        } else {
            lockedRestoreDistance = nil
            setDistanceFromBottom(0)
        }

        initialPositionApplied = true
        pendingInitialState = nil
        updateMountedRows(rangeOverride: restoredRange)
        // A saved target is already the authoritative persisted state. Do not
        // replace it with a clamped/intermediate first-layout coordinate.
        if shouldPublishInitialPosition {
            emitViewportSnapshot()
        }
    }

    func currentDistanceFromBottom() -> CGFloat {
        max(0, transcriptDocumentView.frame.height - contentView.bounds.maxY)
    }

    func currentViewportAnchor() -> VirtualTranscriptAnchor? {
        virtualLayout.viewportAnchor(
            at: contentView.bounds.minY - transcriptRowsOrigin
        )
    }

    func restoredViewportTop(from state: SessionScrollState) -> CGFloat? {
        guard let anchor = state.virtualTranscript?.viewportAnchor,
            let rowRelativeTop = virtualLayout.viewportTop(restoring: anchor)
        else { return nil }
        return transcriptRowsOrigin + rowRelativeTop
    }

    func setDistanceFromBottom(_ distance: CGFloat) {
        let viewportHeight = contentView.bounds.height
        let documentHeight = transcriptDocumentView.frame.height
        setViewportTop(max(0, documentHeight - viewportHeight - max(0, distance)))
    }

    func setViewportTop(_ requestedTop: CGFloat) {
        let maximum = max(0, transcriptDocumentView.frame.height - contentView.bounds.height)
        let top = min(max(0, requestedTop), maximum)
        guard abs(contentView.bounds.minY - top) > 0.25 else { return }
        applyPositionTransaction {
            contentView.scroll(to: CGPoint(x: 0, y: top))
            reflectScrolledClipView(contentView)
        }
        lastDistanceFromBottom = currentDistanceFromBottom()
    }

    func applyPositionTransaction(_ body: () -> Void) {
        positionApplicationDepth += 1
        defer { positionApplicationDepth -= 1 }
        body()
    }

    func scrollToBottom() {
        cancelDisclosureViewportAnchor()
        lockedRestoreDistance = nil
        commitPendingMeasurements()
        bottomJumpGate.begin()
        setDistanceFromBottom(0)
        updateMountedRows()
        emitViewportSnapshot()
        resolveBottomJumpIfPossible()
    }

    func viewportDidScroll() {
        // AppKit can resize the clip view again after `viewWillMove(nil)`.
        // That teardown geometry is not a user position and must never replace
        // the valid snapshot captured immediately before detachment.
        guard !isDetaching else { return }
        let previousDistance = lastDistanceFromBottom
        let distance = currentDistanceFromBottom()
        lastDistanceFromBottom = distance
        let viewportTop = contentView.bounds.minY
        let isUserMovement = isDraggingScrollerKnob || isHandlingUserInput || isLiveScrolling
        if let lastObservedViewportTop, isUserMovement {
            pendingWindowScrollDelta += viewportTop - lastObservedViewportTop
            runwayMotion.observe(
                viewportTop: viewportTop,
                timestamp: CACurrentMediaTime()
            )
        } else if !isApplyingPosition {
            pendingWindowScrollDelta = 0
            if runwayMotion.pointsPerSecond == 0 {
                runwayMotion.reset(
                    viewportTop: viewportTop,
                    timestamp: CACurrentMediaTime()
                )
            }
        }
        lastObservedViewportTop = viewportTop
        if isDraggingScrollerKnob || isHandlingUserInput || isLiveScrolling {
            // Native scrolling may deliver more bounds changes than the screen
            // can present. Reconcile the virtual window once on the next real
            // display frame; the prepared pixel runway covers that handoff.
            requestMountedRowsUpdate()
        } else {
            updateMountedRows()
        }

        let atBottom = distance <= Self.atBottomThreshold
        publishBottomState(atBottom)
        let isRecentUserMovement =
            isHandlingUserInput || isLiveScrolling
            || ProcessInfo.processInfo.systemUptime <= userInputDeadline
        // Only recent user movement can change follow intent. The short intent
        // window still catches AppKit bounds notifications delivered after the
        // wheel/key callback, while remount and remeasurement geometry cannot
        // silently turn follow off.
        if !isApplyingPosition, isRecentUserMovement,
            distance > previousDistance + 0.5, followsLatest
        {
            followsLatest = false
            onFollowStateChange?(false)
        } else if !isApplyingPosition, isRecentUserMovement, atBottom, !followsLatest {
            followsLatest = true
            onFollowStateChange?(true)
        }

        // Persist only while AppKit is dispatching an actual user scrolling
        // event. Bounds changes also fire for document resize, restoration,
        // and teardown; treating those as user position is what reset chats
        // to the first row during navigation.
        if !isApplyingPosition, isHandlingUserInput || isLiveScrolling {
            lockedRestoreDistance = nil
            // A live scroll (including knob tracking) publishes one exact
            // snapshot in didEndLiveScroll. Rebuilding it for every bounds
            // tick adds work without making restoration more accurate.
            if !isLiveScrolling {
                emitViewportSnapshot()
            }
        }
        checkForHistoryPrefetch()
    }

    func markRecentUserInput() {
        userInputDeadline = ProcessInfo.processInfo.systemUptime + 0.35
    }

    func publishBottomState(_ isAtBottom: Bool) {
        guard lastBottomState != isAtBottom else { return }
        lastBottomState = isAtBottom
        onBottomStateChange?(isAtBottom)
    }

    func checkForHistoryPrefetch(force: Bool = false) {
        guard hasOlderHistory, let oldestKey = rows.first?.layoutKey else { return }
        let distanceFromTop = contentView.bounds.minY
        let threshold = max(600, contentView.bounds.height * 1.5)
        historyPrefetchPolicy.requestIfNeeded(
            oldestKey: oldestKey,
            distanceFromTop: distanceFromTop,
            threshold: threshold,
            force: force
        ) { [weak self] in
            self?.onNearTop?() == true
        }
    }

    func resolveBottomJumpIfPossible() {
        guard bottomJumpGate.isActive,
            initialPositionApplied,
            contentView.bounds.height > 0
        else { return }
        let requiredKeys = virtualLayout.keys(in: plannedMountedRange())
        let mountedKeys = Set(mountedHosts.keys)
        guard requiredKeys.isSubset(of: mountedKeys) else {
            updateMountedRows()
            return
        }
        let resolvedKeys = TranscriptMountedWindowReadiness.resolvedKeys(
            required: requiredKeys,
            measurements: measurements
        ) { key in
            guard let host = mountedHosts[key] else { return false }
            return host.isAttachmentGeometryReady && host.isPresentationReady
        }
        _ = bottomJumpGate.resolve(
            requiredKeys: requiredKeys,
            resolvedKeys: resolvedKeys,
            hasPendingMeasurements: !pendingMeasuredHeights.isEmpty
        )
    }

    func updateInitialPresentationReadiness() {
        guard !initialPresentationGate.isReady,
            !isDetaching,
            initialPositionApplied,
            contentView.bounds.height > 0
        else { return }

        let requiredKeys = virtualLayout.keys(in: plannedMountedRange())
        let mountedKeys = Set(mountedHosts.keys)
        guard requiredKeys.isSubset(of: mountedKeys) else {
            updateMountedRows()
            return
        }
        let resolvedKeys = TranscriptMountedWindowReadiness.resolvedKeys(
            required: requiredKeys,
            measurements: measurements
        ) { key in
            guard let host = mountedHosts[key] else { return false }
            return host.isAttachmentGeometryReady && host.isPresentationReady
        }
        guard
            initialPresentationGate.resolve(
                isHydrating: isLoadingInitialHistory || isPreparingInitialProjection,
                isActiveProjectionPending: isActiveProjectionPending,
                requiredKeys: requiredKeys,
                resolvedKeys: resolvedKeys,
                hasPendingMeasurements: !pendingMeasuredHeights.isEmpty
            )
        else { return }

        applyPositionTransaction {
            if initialBottomPin.isActive {
                setDistanceFromBottom(0)
            }
            initialBottomPin.release()
            transcriptDocumentView.alphaValue = 1
            transcriptDocumentView.setAccessibilityHidden(false)
            verticalScroller?.isEnabled = true
        }
        onInitialPresentationReady?()
    }

    func updatePaginationLoadingIndicator(isPresented: Bool) {
        if isPresented {
            paginationLoadingIndicator.startAnimation(nil)
        } else {
            paginationLoadingIndicator.stopAnimation(nil)
        }
        positionPaginationLoadingIndicator()
    }

    func positionPaginationLoadingIndicator() {
        guard paginationHeaderLayout.reservesSpace else {
            paginationLoadingIndicator.frame = .zero
            return
        }
        paginationLoadingIndicator.sizeToFit()
        let size = paginationLoadingIndicator.frame.size
        paginationLoadingIndicator.frame = CGRect(
            x: (max(1, contentView.bounds.width) - size.width) / 2,
            y: Self.topPadding
                + (paginationHeaderLayout.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func emitViewportSnapshot() {
        guard !isDetaching, initialPositionConfigured,
            contentView.bounds.height > 0
        else { return }
        let distance = currentDistanceFromBottom()
        let atBottom = distance <= Self.atBottomThreshold
        publishBottomState(atBottom)
        let state = SessionScrollState(
            distanceFromBottom: distance,
            measurementCaches: measurementCache.caches,
            measurementCacheLRU: measurementCache.lru,
            virtualTranscript: currentVirtualRestoreState(
                viewportAnchor: currentViewportAnchor()
            ),
            followMode: followsLatest ? .followingLatest : .staticPosition
        )
        lastStableScrollState = state
        viewportSnapshotGeneration &+= 1
        onViewportChange?(state)
    }

    func republishLastStableScrollState() {
        guard var state = lastStableScrollState else { return }
        // Measurements learned after the last wheel event are still useful on
        // the next mount, but they do not authorize a different position.
        state.measurementCaches = measurementCache.caches
        state.measurementCacheLRU = measurementCache.lru
        state.virtualTranscript = currentVirtualRestoreState(
            viewportAnchor: state.virtualTranscript?.viewportAnchor
        )
        lastStableScrollState = state
        onViewportChange?(state)
    }

    func currentVirtualRestoreState(
        viewportAnchor: VirtualTranscriptAnchor?
    ) -> SessionVirtualTranscriptRestoreState {
        let targetKeys = virtualWindowHandoff.targetKeys
        let restoreKeys = targetKeys.isEmpty ? Set(mountedHosts.keys) : targetKeys
        let renderedWindow = virtualLayout.renderedWindow(covering: restoreKeys).map {
            SessionRenderedTranscriptWindow(anchorKey: $0.anchorKey, count: $0.count)
        }
        return SessionVirtualTranscriptRestoreState(
            measurementCacheKey: measurementCache.activeKey,
            // Dictionary assignment is copy-on-write. Restore already ignores
            // keys absent from the current transcript, so this keeps viewport
            // snapshots O(mounted rows) instead of walking the full history.
            rowHeightsByKey: measurements.heightsByKey,
            // The revision-carrying snapshot rides along (also copy-on-write)
            // so restore can reject settled-row heights whose content changed
            // while the pane was closed.
            settledRowsByKey: measurementCache.settledRows,
            renderedWindow: renderedWindow,
            viewportAnchor: viewportAnchor
        )
    }
}

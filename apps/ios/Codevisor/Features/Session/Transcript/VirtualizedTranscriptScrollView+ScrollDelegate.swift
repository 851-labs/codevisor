import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

// MARK: - ScrollDelegate

extension VirtualizedTranscriptScrollView {
    func scrollViewWillBeginDragging(_: UIScrollView) {
        measurementCommitGate.draggingDidBegin()
        cancelDisclosureViewportAnchor()
        bottomJumpGate.cancel()
        lockedRestoreDistance = nil
        isExplicitUserScroll = false
        // Touching down interrupts UIKit's deceleration. Flush measurements
        // retained from that momentum phase before the new drag advances.
        commitPendingMeasurements()
    }

    func scrollViewShouldScrollToTop(_: UIScrollView) -> Bool {
        cancelDisclosureViewportAnchor()
        bottomJumpGate.cancel()
        lockedRestoreDistance = nil
        isExplicitUserScroll = true
        return false
    }

    func scrollViewDidScroll(_: UIScrollView) {
        guard !isDetaching else { return }
        let previousDistance = lastDistanceFromBottom
        let distance = currentDistanceFromBottom()
        lastDistanceFromBottom = distance
        let isUserMovement =
            isTracking || isDragging || isDecelerating
            || isExplicitUserScroll
        if let lastObservedContentOffsetY, isUserMovement {
            pendingWindowScrollDelta += contentOffset.y - lastObservedContentOffsetY
        } else if !isApplyingPosition {
            pendingWindowScrollDelta = 0
        }
        lastObservedContentOffsetY = contentOffset.y
        if initialPositionApplied {
            if isUserMovement {
                requestMountedRowsUpdate()
            } else {
                updateMountedRows()
            }
        }

        let atBottom = distance <= Self.atBottomThreshold
        publishBottomState(atBottom)
        if !isApplyingPosition, isUserMovement,
            distance > previousDistance + 0.5, followsLatest
        {
            followsLatest = false
            onFollowStateChange?(false)
        } else if !isApplyingPosition, isUserMovement, atBottom, !followsLatest {
            followsLatest = true
            onFollowStateChange?(true)
        }
        if !isApplyingPosition, isUserMovement {
            lockedRestoreDistance = nil
            emitViewportSnapshot()
        }
        checkForHistoryPrefetch()
    }

    func scrollViewDidEndDragging(
        _: UIScrollView,
        willDecelerate decelerate: Bool,
    ) {
        measurementCommitGate.draggingDidEnd(willDecelerate: decelerate)
        if !decelerate { finishNativeScrollInteraction() }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) {
        measurementCommitGate.interactionDidEnd()
        finishNativeScrollInteraction()
    }

    func scrollViewDidEndScrollingAnimation(_: UIScrollView) {
        measurementCommitGate.interactionDidEnd()
        finishNativeScrollInteraction()
    }
}

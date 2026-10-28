import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

extension VirtualizedTranscriptScrollView {
  func scrollViewWillBeginDragging(_: UIScrollView) {
    cancelDisclosureViewportAnchor()
    bottomJumpGate.cancel()
    lockedRestoreDistance = nil
    isExplicitUserScroll = false
    beginKeyboardDrag()
  }

  func scrollViewWillEndDragging(
    _: UIScrollView,
    withVelocity _: CGPoint,
    targetContentOffset: UnsafeMutablePointer<CGPoint>
  ) {
    endKeyboardDrag(targetContentOffset: targetContentOffset)
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
    carrySendFlightsWithUserScroll()
    holdForKeyboardDrag()
    let previousDistance = lastDistanceFromBottom
    let distance = currentDistanceFromBottom()
    lastDistanceFromBottom = distance
    let isNativeMovement =
      initialPositionApplied && !isApplyingPosition && lastViewportSize == bounds.size
    let isUserMovement =
      isTracking || isDragging || isDecelerating
      || isExplicitUserScroll || isNativeMovement
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
    updateCollapsibleEarlierHistory()
  }

  func scrollViewDidEndDragging(
    _: UIScrollView,
    willDecelerate decelerate: Bool,
  ) {
    holdsForKeyboardDrag = false
    setKeyboardDismissPadding(0)
    if !decelerate { finishNativeScrollInteraction() }
  }

  func scrollViewDidEndDecelerating(_: UIScrollView) {
    finishNativeScrollInteraction()
  }

  func scrollViewDidEndScrollingAnimation(_: UIScrollView) {
    finishNativeScrollInteraction()
  }
}

import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  /// The flight can end before a deferred replacement host has measured.
  /// Keep history at its landed coordinates and the new assistant hidden
  /// until its height, document size, and bottom offset can paint together.
  func completePendingSendPresentationIfPossible() {
    guard !isApplyingSendCompletion,
      sendCompletionSourceViewportYByRowKey != nil,
      let request = activeSendAnimationRequest,
      sendPresentationLifecycle.owns(token: request.token)
    else { return }

    guard !isUpdatingMountedRows else {
      needsLayout = true
      return
    }

    isApplyingSendCompletion = true
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      isApplyingSendCompletion = false
    }
    applyDeferredSendProjectionIfNeeded()
    commitPendingMeasurements()
    synchronizePendingSendHistoryPositions()

    guard
      TranscriptSendCompletionReadiness.isReady(
        userMessageID: request.messageID,
        rows: rows,
        measurements: measurements,
        hasPendingMeasurement: { pendingMeasuredHeights[$0] != nil },
        hosts: mountedHosts
      )
    else { return }

    guard sendPresentationLifecycle.complete(token: request.token) else { return }
    clearSendPresentationVisuals()
  }
}

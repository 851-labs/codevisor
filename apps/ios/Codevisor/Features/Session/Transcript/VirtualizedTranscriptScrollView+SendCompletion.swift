import CodevisorCore
import CodevisorUI
import QuartzCore
import TranscriptKit
import UIKit

extension VirtualizedTranscriptScrollView {
  /// UIKit reports replacement-root measurements asynchronously. Hold the
  /// landed transcript through those callbacks, then reveal the assistant
  /// in the transaction that owns its committed height and scroll offset.
  func completePendingSendPresentationIfPossible() {
    guard !isApplyingSendCompletion,
      sendCompletionSourceScreenYByRowKey != nil,
      let request = activeSendAnimationRequest,
      sendPresentationLifecycle.owns(token: request.token)
    else { return }

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
        hasPendingMeasurement: { pendingMeasurements[$0] != nil },
        hosts: mountedHosts
      )
    else { return }

    guard sendPresentationLifecycle.complete(token: request.token) else { return }
    let notifyCompletion = sendCompletionNotifiesCompletion
    clearSendPresentationVisuals()
    if notifyCompletion { onSendAnimationCompleted?(request) }
  }
}

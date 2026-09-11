import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

// MARK: - FrameDriver

extension VirtualizedTranscriptScrollView: TranscriptFrameAdapter {
  func prepareForPresentationAttachment() {
    if initialPresentationGate.isReady, let state = lastStableScrollState {
      pendingInitialState = state
      initialPositionApplied = false
      followsLatest = state.isAtBottom
      lockedRestoreDistance = state.isAtBottom ? nil : state.distanceFromBottom
    }
    hasReceivedScrollCommandForAttachment = false
    isAwaitingWarmProjection = initialPresentationGate.isReady
    projectedRowsVersion = nil
    receivedProjectionRevision = nil
    activeRowsVersion = nil
  }

  /// Pause native work without destroying the visible row window. The next
  /// SwiftUI owner installs fresh callbacks before reconciling new content.
  func suspendPresentation() {
    if presentationRole == .foreground {
      // Capture the live, post-measurement coordinate before UIKit
      // starts changing bounds and safe-area geometry during teardown.
      emitViewportSnapshot()
    } else {
      republishLastStableScrollState()
    }
    isDetaching = true
    uninstallPresentationDisplayLink()
    measurementCommitTask?.cancel()
    measurementCommitTask = nil
    // Retained hosts may have reported their size just before this frame
    // was cancelled. Keep those measurements for reattachment: an unchanged
    // host will not report again, leaving the initial canvas hidden forever.
    // UIKit may also omit the end-of-deceleration callback after detachment.
    measurementCommitGate.interactionDidEnd()
    bottomJumpGate.cancel()
    deferredRowsDuringScroll = nil
    deferredActiveRowsRange = nil
    deferredProjectionRevision = nil
    olderHistoryPresentationTarget = nil
    disclosureAnchorReleaseTask?.cancel()
    interruptSendPresentation()
    rowContent = nil
    openMarkdownLink = nil
    claimSendAnimation = nil
    onSendAnimationStarted = nil
    onSendAnimationCompleted = nil
    onViewportChange = nil
    onBottomStateChange = nil
    onFollowStateChange = nil
    onNearTop = nil
    onOlderHistoryPresented = nil
  }

  func prepareForDismantle() {
    suspendPresentation()
    pendingMeasurements.removeAll(keepingCapacity: false)
    for host in mountedHosts.values {
      host.removeFromSuperview()
      host.detachFromParent()
    }
    mountedHosts.removeAll(keepingCapacity: false)
    virtualWindowHandoff.reset()
    discardParkedHosts()
  }

  func installPresentationDisplayLink() {
    guard presentationDisplayLink == nil, let window else { return }
    guard
      let displayLink = window.screen.displayLink(
        withTarget: self,
        selector: #selector(presentationDisplayLinkDidFire(_:))
      )
    else { return }
    let rate = Float(max(1, window.screen.maximumFramesPerSecond))
    displayLink.preferredFrameRateRange = CAFrameRateRange(
      minimum: rate,
      maximum: rate,
      preferred: rate
    )
    displayLink.isPaused = true
    displayLink.add(to: .main, forMode: .common)
    presentationDisplayLink = displayLink
    streamingTextFrameClock.setFrameRequester { [weak self] in
      self?.requestDisplayFrame()
    }
    updatePresentationFrameDriverRegistration()
    if !pendingMeasurements.isEmpty {
      requestDisplayFrame()
    }
  }

  func uninstallPresentationDisplayLink() {
    streamingTextFrameClock.setFrameRequester(nil)
    unregisterPresentationFrameDriver()
    presentationDisplayLink?.invalidate()
    presentationDisplayLink = nil
    displayFrameRequested = false
    modelPresentationFrameRequested = false
    mountedRowsUpdateRequested = false
  }

  func updatePresentationFrameDriverRegistration() {
    guard presentationRole == .foreground,
      presentationFrameDriverToken == nil,
      let presentationDisplayLink,
      let sessionController,
      let window
    else {
      if presentationRole != .foreground {
        unregisterPresentationFrameDriver()
      }
      return
    }
    presentationFrameDriverToken = sessionController.registerTranscriptFrameDriver(
      maximumFramesPerSecond: max(1, window.screen.maximumFramesPerSecond)
    ) { [weak self] in
      self?.requestModelPresentationFrame()
    }
    // Keep the local link alive only through explicit frame requests.
    presentationDisplayLink.isPaused = !displayFrameRequested
  }

  func unregisterPresentationFrameDriver() {
    if let presentationFrameDriverToken {
      sessionController?.unregisterTranscriptFrameDriver(presentationFrameDriverToken)
      self.presentationFrameDriverToken = nil
    }
  }

  func requestDisplayFrame() {
    guard let presentationDisplayLink else { return }
    displayFrameRequested = true
    presentationDisplayLink.isPaused = false
  }

  func requestModelPresentationFrame() {
    modelPresentationFrameRequested = true
    requestDisplayFrame()
  }

  func requestMountedRowsUpdate() {
    guard presentationDisplayLink != nil else {
      updateMountedRows()
      return
    }
    mountedRowsUpdateRequested = true
    requestDisplayFrame()
  }

  @objc func presentationDisplayLinkDidFire(_ displayLink: CADisplayLink) {
    surfaceController.presentFrame(at: displayLink.timestamp, adapter: self)
    displayLink.isPaused = !displayFrameRequested
  }

  func prepareFrameBudget() {
    remainingMountsThisFrame = maximumMountsPerFrame
  }

  func presentPendingModel() {
    if let presentationFrameDriverToken {
      sessionController?.transcriptPresentationFrameDidFire(presentationFrameDriverToken)
    }
  }

  var hasPendingMeasurements: Bool {
    !pendingMeasurements.isEmpty
  }

  var allowsMeasurementCommit: Bool {
    measurementCommitGate.allowsGeometryCommit
  }

  func finishPresentationFrame() {
  }
}

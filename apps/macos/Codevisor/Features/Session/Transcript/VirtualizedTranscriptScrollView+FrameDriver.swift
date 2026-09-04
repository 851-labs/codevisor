import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

// MARK: - FrameDriver

extension VirtualizedTranscriptScrollView {
  /// Starts a new SwiftUI ownership lifetime without discarding the native
  /// presentation. Version counters are local to each SwiftUI tree, so make
  /// their first complete projection authoritative even if its number happens
  /// to equal the previous owner's last counter.
  func prepareForPresentationAttachment() {
    if initialPresentationGate.isReady {
      persistViewport()
      // Retain the hosts, but restore the saved row/offset once this owner's
      // projection is ready. AppKit may have clamped or reset the detached
      // clip view, and messages may have arrived while the chat was hidden.
      if let state = lastStableScrollState {
        pendingInitialState = state
        initialPositionApplied = false
        followsLatest = state.isAtBottom
        lockedRestoreDistance = state.isAtBottom ? nil : state.distanceFromBottom
      }
    }
    hasReceivedScrollCommandForAttachment = false
    isAwaitingWarmProjection = initialPresentationGate.isReady
    projectedRowsVersion = nil
    receivedProjectionRevision = nil
    activeRowsVersion = nil
  }

  func prepareForDismantle() {
    persistViewport()
    isDetaching = true
    cancelDisclosureViewportAnchor()
    bottomJumpGate.cancel()
    isHandlingUserInput = false
    isLiveScrolling = false
    userInputDeadline = 0
    uninstallPresentationFrameDriver()
    interruptSendPresentation()
    finishAllDisclosureCollapsePresentations()
    rowContent = nil
    openMarkdownLink = nil
    claimSendAnimation = nil
    onViewportChange = nil
    onBottomStateChange = nil
    onFollowStateChange = nil
    onNearTop = nil
    onInitialPresentationReady = nil
  }

  func installPresentationFrameDriver() {
    guard presentationDisplayLink == nil, let window, let sessionController else { return }
    let maximumFramesPerSecond = max(1, window.screen?.maximumFramesPerSecond ?? 60)
    let displayLink = displayLink(
      target: self,
      selector: #selector(presentationDisplayLinkDidFire(_:))
    )
    let rate = Float(maximumFramesPerSecond)
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
    presentationFrameDriverToken = sessionController.registerTranscriptFrameDriver(
      maximumFramesPerSecond: maximumFramesPerSecond
    ) { [weak self] in
      self?.requestModelPresentationFrame()
    }
    if !pendingMeasuredHeights.isEmpty || !retiringHosts.isEmpty {
      requestDisplayFrame()
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowScreenDidChange(_:)),
      name: NSWindow.didChangeScreenNotification,
      object: window
    )
  }

  @objc func windowScreenDidChange(_: Notification) {
    reinstallPresentationFrameDriver()
  }

  func reinstallPresentationFrameDriver() {
    uninstallPresentationFrameDriver()
    installPresentationFrameDriver()
  }

  func uninstallPresentationFrameDriver() {
    streamingTextFrameClock.setFrameRequester(nil)
    NotificationCenter.default.removeObserver(
      self,
      name: NSWindow.didChangeScreenNotification,
      object: nil
    )
    presentationDisplayLink?.invalidate()
    presentationDisplayLink = nil
    displayFrameRequested = false
    modelPresentationFrameRequested = false
    mountedRowsUpdateRequested = false
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
    guard !isUpdatingMountedRows else {
      deferMountedRowsUpdateUntilLayoutCompletes()
      return
    }
    guard presentationDisplayLink != nil, !inLiveResize else {
      updateMountedRows()
      return
    }
    mountedRowsUpdateRequested = true
    requestDisplayFrame()
  }

  func deferMountedRowsUpdateUntilLayoutCompletes(
    rangeOverride: Range<Int>? = nil
  ) {
    // A display-link callback cannot run inside the current AppKit layout
    // stack, so it is the cheapest coalescing boundary when available.
    if rangeOverride == nil, presentationDisplayLink != nil, !inLiveResize {
      mountedRowsUpdateRequested = true
      requestDisplayFrame()
      return
    }

    deferredMountedRowsUpdateRequested = true
    if let rangeOverride {
      deferredMountedRowsRangeOverride = rangeOverride
    }
    guard !deferredMountedRowsUpdateScheduled else { return }
    deferredMountedRowsUpdateScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.deferredMountedRowsUpdateScheduled = false
      guard self.deferredMountedRowsUpdateRequested else { return }
      self.deferredMountedRowsUpdateRequested = false
      let rangeOverride = self.deferredMountedRowsRangeOverride
      self.deferredMountedRowsRangeOverride = nil
      guard !self.isDetaching else { return }
      if let rangeOverride {
        self.updateMountedRows(rangeOverride: rangeOverride)
      } else {
        self.requestMountedRowsUpdate()
      }
    }
  }

  @objc func presentationDisplayLinkDidFire(_ displayLink: CADisplayLink) {
    let shouldPresentModel = modelPresentationFrameRequested
    let shouldUpdateMountedRows = mountedRowsUpdateRequested
    remainingMountsThisFrame = maximumMountsPerFrame
    remainingRunwayPreparationsThisFrame = maximumRunwayPreparationsPerFrame
    displayFrameRequested = false
    modelPresentationFrameRequested = false
    mountedRowsUpdateRequested = false
    if shouldPresentModel, let presentationFrameDriverToken {
      sessionController?.transcriptPresentationFrameDidFire(presentationFrameDriverToken)
    }
    if shouldUpdateMountedRows {
      updateMountedRows()
    }
    if !pendingMeasuredHeights.isEmpty {
      commitPendingMeasurements()
    }
    streamingTextFrameClock.tick(at: displayLink.timestamp)
    if !isLiveScrolling, !isHandlingUserInput {
      drainRetiringHosts(limit: 1)
    }
    if !retiringHosts.isEmpty {
      requestDisplayFrame()
    }
    displayLink.isPaused = !displayFrameRequested
  }
}

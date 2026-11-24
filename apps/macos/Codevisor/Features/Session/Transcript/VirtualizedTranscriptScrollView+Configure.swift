import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  func configureWhenOnScreen(_ input: TranscriptSurfaceInput, callbacks: TranscriptSurfaceCallbacks) {
    guard !defersOffscreenRendering || sessionController !== input.sessionController else {
      offscreenConfiguration = (input, callbacks)
      return
    }
    offscreenConfiguration = nil
    configure(input, callbacks: callbacks)
  }

  func configure(_ input: TranscriptSurfaceInput, callbacks: TranscriptSurfaceCallbacks) {
    let traceStart = TranscriptPerformanceTrace.begin()
    defer {
      surfaceController.recordPerformanceTrace(
        "macos.configure", since: traceStart,
        hostCount: mountedHosts.count, distance: currentDistanceFromBottom())
    }

    let newSessionController = input.sessionController
    let newProjectedRows = input.rows
    let newActiveRows = input.activeRows
    let newActiveRowsVersion = input.activeRowsVersion
    let newRowsVersion = input.rowsVersion
    let newProjectionRevision = input.projectionRevision
    let initialState = input.initialState
    let newFollowsLatest = input.followsLatest
    let newHasOlderHistory = input.hasOlderHistory
    let newShowsOlderHistoryLoadingIndicator = input.showsOlderHistoryLoadingIndicator
    let newIsLoadingInitialHistory = input.isLoadingInitialHistory
    let newIsPreparingInitialProjection = input.isPreparingInitialProjection
    let newIsActiveProjectionPending = input.isActiveProjectionPending
    let newIsAwaitingFirstActiveProjection = input.isAwaitingFirstActiveProjection
    let newLayoutFingerprint = input.layoutFingerprint
    let newScrollCommand = input.scrollCommand
    if !hasReceivedScrollCommandForAttachment {
      scrollCommand = newScrollCommand
      hasReceivedScrollCommandForAttachment = true
    }
    let newSendAnimationRequest = input.sendAnimationRequest
    let newReduceMotion = input.reduceMotion
    if sessionController !== newSessionController { adoptSessionController(newSessionController) }
    adoptCallbacks(callbacks)
    applyBottomFade(input.bottomFade)
    updatePaginationLoadingIndicator(
      isPresented: newShowsOlderHistoryLoadingIndicator
    )
    isLoadingInitialHistory = newIsLoadingInitialHistory
    isPreparingInitialProjection = newIsPreparingInitialProjection
    isActiveProjectionPending = newIsActiveProjectionPending
    isAwaitingFirstActiveProjection = newIsAwaitingFirstActiveProjection
    if isAwaitingWarmProjection,
      newIsPreparingInitialProjection || newIsAwaitingFirstActiveProjection
    {
      return
    }
    isAwaitingWarmProjection = false
    guard !newIsPreparingInitialProjection else { return }
    let projectedRowsChanged = projectedRowsVersion != newRowsVersion
    let projectionRevisionChanged = receivedProjectionRevision != newProjectionRevision
    let activeRowsChanged = activeRowsVersion != newActiveRowsVersion
    let bottomClearanceChanged = surfaceController.adoptBottomClearance(input.bottomContentClearance)
    hasOlderHistory = newHasOlderHistory
    let paginationHeaderReservationChanged = paginationHeaderLayout.reserveIfNeeded(
      hasOlderHistory: newHasOlderHistory,
      isPresented: newShowsOlderHistoryLoadingIndicator
    )
    positionPaginationLoadingIndicator()
    reduceMotion = newReduceMotion
    sendTransitions.session = sessionController.map(ObjectIdentifier.init)
    sendTransitions.reduceMotion = newReduceMotion
    sendTransitions.claim = callbacks.claimSendAnimation
    sendTransitions.onStarted = callbacks.onSendAnimationStarted
    sendTransitions.onCompleted = callbacks.onSendAnimationCompleted
    sendTransitions.receive(newSendAnimationRequest, isForeground: true)
    let contentShift = sendTransitions.beginContentShift()
    defer { sendTransitions.commitContentShift(contentShift) }

    let layoutFingerprintChanged = layoutFingerprint != newLayoutFingerprint
    layoutFingerprint = newLayoutFingerprint

    if surfaceController.configureInitialPosition(initialState, followsLatest: newFollowsLatest) {
      pendingInitialState = initialState
      lastStableScrollState = initialState
      scrollCommand = newScrollCommand
    }

    surfaceController.currentScrollCommand = scrollCommand
    surfaceController.observeStreamingPresentation(input)

    if layoutFingerprintChanged {
      sendTransitions.landFlights()
    }

    let rebuiltRows: Bool
    if projectedRowsChanged || projectionRevisionChanged || layoutFingerprintChanged || bottomClearanceChanged {
      projectedRows = newProjectedRows
      projectedRowsVersion = newRowsVersion
      receivedProjectionRevision = newProjectionRevision
      activeRows = newActiveRows
      activeRowsVersion = newActiveRowsVersion
      let resolution = resolvedRows(
        projectedRows: newProjectedRows,
        activeRows: newActiveRows
      )
      activeRowsRange = resolution.activeRange
      rebuiltRows = applyRows(
        resolution.rows,
        layoutFingerprintChanged: layoutFingerprintChanged
      )
    } else if activeRowsChanged {
      activeRowsVersion = newActiveRowsVersion
      rebuiltRows = applyActiveRows(newActiveRows)
    } else {
      rebuiltRows = false
    }
    if paginationHeaderReservationChanged, !rebuiltRows {
      rebuildDocumentGeometry()
    }

    if newScrollCommand != scrollCommand {
      scrollCommand = newScrollCommand
      lockedRestoreDistance = nil
      followsLatest = true
      scrollToBottom()
    }

    if projectedRowsChanged || projectionRevisionChanged || activeRowsChanged {
      scheduleFindRefreshIfNeeded()
    }

    applyPendingInitialPositionIfPossible()
    presentDeferredActivePlaceholderIfNeeded()
    updateInitialPresentationReadiness()
    resolveBottomJumpIfPossible()
    checkForHistoryPrefetch()
  }

  private func adoptCallbacks(_ callbacks: TranscriptSurfaceCallbacks) {
    rowContent = callbacks.rowContent
    markdownImageLoader = callbacks.markdownImageLoader ?? .remote
    openMarkdownLink = callbacks.openMarkdownLink
    markdownFileActions = callbacks.markdownFileActions
    markdownWebLinkActions = callbacks.markdownWebLinkActions
    onViewportChange = callbacks.onViewportChange
    onBottomStateChange = callbacks.onBottomStateChange
    onEarlierHistoryCollapseChange = callbacks.onEarlierHistoryCollapseChange
    onFollowStateChange = callbacks.onFollowStateChange
    onNearTop = callbacks.onNearTop
  }

  private func adoptSessionController(_ controller: SessionController?) {
    uninstallPresentationFrameDriver()
    hostPool.retireParkedHosts()
    sessionController = controller
    collapsibleEarlierHistorySection = nil
    historyPrefetchPolicy = TranscriptHistoryPrefetchPolicy()
    deferredActivePlaceholderKey = nil
    installPresentationFrameDriver()
  }
}

import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

// MARK: - Configure

extension VirtualizedTranscriptScrollView {
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
    // Each SwiftUI owner starts its own command counter. Its first value is
    // a baseline, not a new jump; later changes (including during projection
    // loading) remain actionable when the rows are ready.
    if !hasReceivedScrollCommandForAttachment {
      scrollCommand = newScrollCommand
      hasReceivedScrollCommandForAttachment = true
    }
    let newSendAnimationRequest = input.sendAnimationRequest
    let newReduceMotion = input.reduceMotion
    let newRowContent = callbacks.rowContent
    let onViewportChange = callbacks.onViewportChange
    let onBottomStateChange = callbacks.onBottomStateChange
    let onFollowStateChange = callbacks.onFollowStateChange
    let onNearTop = callbacks.onNearTop
    if sessionController !== newSessionController {
      uninstallPresentationFrameDriver()
      sessionController = newSessionController
      historyPrefetchPolicy = TranscriptHistoryPrefetchPolicy()
      deferredActivePlaceholderKey = nil
      installPresentationFrameDriver()
    }
    self.rowContent = newRowContent
    markdownImageLoader = callbacks.markdownImageLoader ?? .remote
    openMarkdownLink = callbacks.openMarkdownLink
    markdownImageActions = callbacks.markdownImageActions
    self.onViewportChange = onViewportChange
    self.onBottomStateChange = onBottomStateChange
    self.onFollowStateChange = onFollowStateChange
    self.onNearTop = onNearTop
    // Pagination feedback describes the fetch, not row projection. Apply
    // it even when the native document is waiting for projected rows so a
    // completed request can never leave the indicator running.
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
      needsLayout = true
      return
    }
    isAwaitingWarmProjection = false
    guard !newIsPreparingInitialProjection else {
      needsLayout = true
      return
    }
    let projectedRowsChanged = projectedRowsVersion != newRowsVersion
    let projectionRevisionChanged = receivedProjectionRevision != newProjectionRevision
    let activeRowsChanged = activeRowsVersion != newActiveRowsVersion
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
    // Everything below can move rows. While a send is live, rows that
    // move are carried from their previous on-screen position by the
    // send's springs instead of jumping.
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
      // A new width re-lays out every row; land any flight first. (A new
      // surface's first configure also lands here, with nothing in flight.)
      sendTransitions.landFlights()
    }

    let rebuiltRows: Bool
    if projectedRowsChanged || projectionRevisionChanged || layoutFingerprintChanged {
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

    applyPendingInitialPositionIfPossible()
    presentDeferredActivePlaceholderIfNeeded()
    updateInitialPresentationReadiness()
    resolveBottomJumpIfPossible()
    checkForHistoryPrefetch()
  }
}

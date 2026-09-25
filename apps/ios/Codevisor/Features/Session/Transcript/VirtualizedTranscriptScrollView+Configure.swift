import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

// MARK: - Configure

extension VirtualizedTranscriptScrollView {
  func configure(_ input: TranscriptSurfaceInput, callbacks: TranscriptSurfaceCallbacks) {
    let traceStart = TranscriptPerformanceTrace.begin()
    defer {
      surfaceController.recordPerformanceTrace(
        "ios.configure", since: traceStart,
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
    let newOlderHistoryPresentationTarget = input.olderHistoryPresentationTarget
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
    let newSendAnimationSourceFrame = input.sendAnimationSourceFrame
    let newPresentationRole = input.presentationRole
    let newReduceMotion = input.reduceMotion
    let newScrollIndicatorBottomInset = input.scrollIndicatorBottomInset
    let newRowContent = callbacks.rowContent
    let onViewportChange = callbacks.onViewportChange
    let onBottomStateChange = callbacks.onBottomStateChange
    let onFollowStateChange = callbacks.onFollowStateChange
    let onNearTop = callbacks.onNearTop
    let onOlderHistoryPresented = callbacks.onOlderHistoryPresented
    if sessionController !== newSessionController {
      unregisterPresentationFrameDriver()
      sessionController = newSessionController
      historyPrefetchPolicy = TranscriptHistoryPrefetchPolicy()
      deferredActivePlaceholderKey = nil
    }
    rowContent = newRowContent
    openMarkdownLink = callbacks.openMarkdownLink
    markdownImageActions = callbacks.markdownImageActions
    self.onViewportChange = onViewportChange
    self.onBottomStateChange = onBottomStateChange
    self.onFollowStateChange = onFollowStateChange
    self.onNearTop = onNearTop
    self.onOlderHistoryPresented = onOlderHistoryPresented
    isPreparingInitialProjection = newIsPreparingInitialProjection
    isActiveProjectionPending = newIsActiveProjectionPending
    isAwaitingFirstActiveProjection = newIsAwaitingFirstActiveProjection
    isLoadingInitialHistory = newIsLoadingInitialHistory
    if isAwaitingWarmProjection,
      newIsPreparingInitialProjection || newIsAwaitingFirstActiveProjection
    {
      setNeedsLayout()
      return
    }
    isAwaitingWarmProjection = false
    guard !newIsPreparingInitialProjection else {
      setNeedsLayout()
      return
    }
    let projectedRowsChanged = projectedRowsVersion != newRowsVersion
    let projectionRevisionChanged = receivedProjectionRevision != newProjectionRevision
    let activeRowsChanged = activeRowsVersion != newActiveRowsVersion
    hasOlderHistory = newHasOlderHistory
    let paginationHeaderReservationChanged = paginationHeaderLayout.reserveIfNeeded(
      hasOlderHistory: newHasOlderHistory,
      isPresented: newShowsOlderHistoryLoadingIndicator,
    )
    updatePaginationLoadingIndicator(
      isPresented: newShowsOlderHistoryLoadingIndicator
    )
    olderHistoryPresentationTarget = newOlderHistoryPresentationTarget
    reduceMotion = newReduceMotion
    updateBottomScrollIndicatorInsetIfNeeded(newScrollIndicatorBottomInset)
    sendAnimationSourceFrame = newSendAnimationSourceFrame
    sendTransitions.session = sessionController.map(ObjectIdentifier.init)
    sendTransitions.reduceMotion = newReduceMotion
    sendTransitions.claim = callbacks.claimSendAnimation
    sendTransitions.onStarted = callbacks.onSendAnimationStarted
    sendTransitions.onCompleted = callbacks.onSendAnimationCompleted
    let becameForeground =
      presentationRole != .foreground
      && newPresentationRole == .foreground
    let leftForeground =
      presentationRole == .foreground
      && newPresentationRole != .foreground
    presentationRole = newPresentationRole
    updatePresentationFrameDriverRegistration()
    if leftForeground {
      sendTransitions.interrupt()
    }
    // Everything below can move rows. While a send is live, rows that
    // move are carried from their previous on-screen position by the
    // send's springs instead of jumping.
    sendTransitions.receive(newSendAnimationRequest, isForeground: newPresentationRole == .foreground)
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
      let prependedItemCount = reversePrependCount(from: rows, to: resolution.rows)
      if prependedItemCount != nil, isNativeScrollInteractionActive,
        !layoutFingerprintChanged
      {
        deferredRowsDuringScroll = resolution.rows
        deferredActiveRowsRange = resolution.activeRange
        deferredProjectionRevision = newProjectionRevision
        rebuiltRows = false
      } else {
        deferredRowsDuringScroll = nil
        deferredActiveRowsRange = nil
        deferredProjectionRevision = nil
        activeRowsRange = resolution.activeRange
        rebuiltRows = applyRows(
          resolution.rows,
          layoutFingerprintChanged: layoutFingerprintChanged
        )
        appliedProjectionRevision = newProjectionRevision
      }
    } else if activeRowsChanged, deferredRowsDuringScroll != nil {
      let resolution = resolvedRows(
        projectedRows: projectedRows,
        activeRows: newActiveRows
      )
      activeRows = newActiveRows
      activeRowsVersion = newActiveRowsVersion
      deferredRowsDuringScroll = resolution.rows
      deferredActiveRowsRange = resolution.activeRange
      rebuiltRows = false
    } else if activeRowsChanged {
      deferredRowsDuringScroll = nil
      deferredActiveRowsRange = nil
      deferredProjectionRevision = nil
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
    if becameForeground {
      // The foreground transcript is now the sole viewport publisher.
      // First-send promotion is always pinned to the newest row, but use
      // the shared state when available so the handoff remains exact.
      if let initialState, initialPositionApplied {
        followsLatest = initialState.followMode.followsLatest
        if !initialState.isAtBottom,
          let restoredTop = restoredViewportTop(from: initialState)
        {
          setViewportTop(restoredTop)
          lockedRestoreDistance = currentDistanceFromBottom()
        } else {
          setDistanceFromBottom(initialState.distanceFromBottom)
        }
      }
      emitViewportSnapshot()
    }
    checkForHistoryPrefetch()
    acknowledgeOlderHistoryPresentationIfPossible()
    setNeedsLayout()
  }
}

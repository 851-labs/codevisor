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
    let newSendAnimationRequest = input.sendAnimationRequest
    let newSendAnimationSourceFrame = input.sendAnimationSourceFrame
    let newPresentationRole = input.presentationRole
    let textAnimationRegistry = input.textAnimationRegistry
    let newReduceMotion = input.reduceMotion
    let newScrollIndicatorBottomInset = input.scrollIndicatorBottomInset
    let newClaimSendAnimation = callbacks.claimSendAnimation
    let newOnSendAnimationStarted = callbacks.onSendAnimationStarted
    let newOnSendAnimationCompleted = callbacks.onSendAnimationCompleted
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
    self.onViewportChange = onViewportChange
    self.onBottomStateChange = onBottomStateChange
    self.onFollowStateChange = onFollowStateChange
    self.onNearTop = onNearTop
    self.onOlderHistoryPresented = onOlderHistoryPresented
    isPreparingInitialProjection = newIsPreparingInitialProjection
    isActiveProjectionPending = newIsActiveProjectionPending
    isAwaitingFirstActiveProjection = newIsAwaitingFirstActiveProjection
    isLoadingInitialHistory = newIsLoadingInitialHistory
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
    claimSendAnimation = newClaimSendAnimation
    onSendAnimationStarted = newOnSendAnimationStarted
    onSendAnimationCompleted = newOnSendAnimationCompleted
    let becameForeground =
      presentationRole != .foreground
      && newPresentationRole == .foreground
    let leftForeground =
      presentationRole == .foreground
      && newPresentationRole != .foreground
    presentationRole = newPresentationRole
    updatePresentationFrameDriverRegistration()
    if leftForeground {
      interruptSendPresentation()
    }

    if newSendAnimationRequest?.token != receivedSendAnimationToken {
      finishSendPresentation(notifyCompletion: true)
      receivedSendAnimationToken = newSendAnimationRequest?.token
      pendingSendAnimationRequest = newSendAnimationRequest
      pendingSendAnimationRowKey = nil
      pendingSendSourceLayout = newSendAnimationRequest == nil ? nil : virtualLayout
      pendingSendSourceScreenYByRowKey =
        newSendAnimationRequest == nil ? nil : sendHistoryScreenYByRowKey()
      synchronizePendingSendTargetVisibility()
      synchronizeSendAssistantVisibility()
    }
    if let request = pendingSendAnimationRequest {
      let requestedKey = TranscriptVirtualRow.ID.message(request.messageID).layoutKey
      if newProjectedRows.contains(where: { row in
        row.layoutKey == requestedKey
          && TranscriptSendAnimationContract.isEligibleTarget(row, for: request.destination)
      }) {
        pendingSendAnimationRowKey = requestedKey
      }
    }

    let layoutFingerprintChanged = layoutFingerprint != newLayoutFingerprint
    layoutFingerprint = newLayoutFingerprint
    if !initialPositionConfigured {
      initialPositionConfigured = true
      pendingInitialState = initialState
      lastStableScrollState = initialState
      initialBottomPin.configure(
        restoresNonBottomPosition: initialState.map { !$0.isAtBottom } ?? false
      )
      followsLatest = initialState?.followMode.followsLatest ?? newFollowsLatest
      if let initialState, !initialState.isAtBottom {
        lockedRestoreDistance = initialState.distanceFromBottom
      }
      if let initialState {
        measurementCache.restore(
          caches: initialState.measurementCaches,
          lru: initialState.measurementCacheLRU
        )
      }
      scrollCommand = newScrollCommand
    }

    let followsAnimationEdge = followsLatest || newScrollCommand != scrollCommand
    textAnimationRegistry.observeProjectedStreams(
      newActiveRows.compactMap { row in
        guard case let .markdownChunk(chunk) = row.content,
          chunk.lifecycle == .receiving
        else { return nil }
        return row.layoutKey
      },
      animatesNewStreams: newPresentationRole == .foreground
        && followsAnimationEdge,
      initialProjectionIsPending: newIsActiveProjectionPending
    )

    if layoutFingerprintChanged, activeSendAnimationRequest != nil {
      finishSendPresentation(notifyCompletion: true)
    }

    let rowProjectionChanged =
      projectedRowsChanged || projectionRevisionChanged || activeRowsChanged
    let rebuiltRows: Bool
    if activeSendAnimationRequest != nil,
      rowProjectionChanged,
      !layoutFingerprintChanged
    {
      deferredSendProjection = DeferredSendProjection(
        projectedRows: newProjectedRows,
        projectedRowsVersion: newRowsVersion,
        projectionRevision: newProjectionRevision,
        activeRows: newActiveRows,
        activeRowsVersion: newActiveRowsVersion
      )
      rebuiltRows = false
    } else if projectedRowsChanged || projectionRevisionChanged || layoutFingerprintChanged {
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
    startPendingSendAnimationIfPossible()
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

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
    let textAnimationRegistry = input.textAnimationRegistry
    let allowsLiveTextAnimation = input.allowsLiveTextAnimation
    let newReduceMotion = input.reduceMotion
    let newClaimSendAnimation = callbacks.claimSendAnimation
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
    openMarkdownLink = callbacks.openMarkdownLink
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
    claimSendAnimation = newClaimSendAnimation

    if newSendAnimationRequest?.token != receivedSendAnimationToken {
      finishSendPresentation()
      receivedSendAnimationToken = newSendAnimationRequest?.token
      pendingSendAnimationRequest = newSendAnimationRequest
      pendingSendAnimationRowKey = nil
      pendingSendSourceLayout = newSendAnimationRequest == nil ? nil : virtualLayout
      pendingSendSourceViewportYByRowKey =
        newSendAnimationRequest == nil ? nil : sendHistoryViewportYByRowKey()
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
      followsLatest = initialState?.isAtBottom ?? newFollowsLatest
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
      animatesNewStreams: allowsLiveTextAnimation && followsAnimationEdge,
      initialProjectionIsPending: newIsActiveProjectionPending
    )

    if layoutFingerprintChanged, activeSendAnimationRequest != nil {
      finishSendPresentation()
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
    startPendingSendAnimationIfPossible()
    updateInitialPresentationReadiness()
    resolveBottomJumpIfPossible()
    checkForHistoryPrefetch()
  }
}

import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

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
      collapsibleEarlierHistorySection = nil
      historyPrefetchPolicy = TranscriptHistoryPrefetchPolicy()
      deferredActivePlaceholderKey = nil
    }
    rowContent = newRowContent
    openMarkdownLink = callbacks.openMarkdownLink
    markdownImageActions = callbacks.markdownImageActions
    self.onViewportChange = onViewportChange
    self.onBottomStateChange = onBottomStateChange
    onEarlierHistoryCollapseChange = callbacks.onEarlierHistoryCollapseChange
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
    topContentClearance = input.topContentClearance
    updateTopContentInsetIfNeeded()
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
        let bottomSpacerShiftOrigin =
          layoutFingerprintChanged ? nil : bottomSpacerShrinkOrigin(to: resolution.rows)
        rebuiltRows = applyRows(
          resolution.rows,
          layoutFingerprintChanged: layoutFingerprintChanged
        )
        if let bottomSpacerShiftOrigin {
          animateBottomSpacerShift(from: bottomSpacerShiftOrigin)
        }
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

extension VirtualizedTranscriptScrollView {
  static let bottomSpacerShiftDuration: TimeInterval = 0.32

  func bottomSpacerShrinkOrigin(to newRows: [TranscriptVirtualRow]) -> CGFloat? {
    guard initialPositionApplied, !reduceMotion, !isNativeScrollInteractionActive,
      !sendTransitions.isPushing, rows.count == newRows.count,
      currentDistanceFromBottom() <= Self.atBottomThreshold,
      let spacerIndex = rows.lastIndex(where: { $0.id == .bottomSpacer }),
      newRows[spacerIndex].id == .bottomSpacer,
      case let .bottomSpacer(oldHeight) = rows[spacerIndex].content,
      case let .bottomSpacer(newHeight) = newRows[spacerIndex].content,
      newHeight < oldHeight,
      zip(rows, newRows).enumerated().allSatisfy({ $0.offset == spacerIndex || $0.element.0 == $0.element.1 })
    else { return nil }
    return contentOffset.y
  }

  func animateBottomSpacerShift(from previousTop: CGFloat) {
    let shift = previousTop - contentOffset.y
    guard abs(shift) > 0.5 else { return }
    let animation = CASpringAnimation(perceptualDuration: Self.bottomSpacerShiftDuration, bounce: 0)
    animation.keyPath = "bounds.origin"
    animation.isAdditive = true
    animation.fromValue = NSValue(cgPoint: CGPoint(x: 0, y: shift))
    animation.toValue = NSValue(cgPoint: .zero)
    animation.duration = animation.settlingDuration
    layer.add(animation, forKey: "codevisor.bottom-spacer-shift")
  }
}

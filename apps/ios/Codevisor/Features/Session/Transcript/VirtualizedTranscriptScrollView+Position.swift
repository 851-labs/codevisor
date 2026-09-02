import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

// MARK: - Position

extension VirtualizedTranscriptScrollView {
  func currentDistanceFromBottom() -> CGFloat {
    viewportGeometry.distanceFromBottom(offsetY: contentOffset.y)
  }

  func currentViewportAnchor() -> VirtualTranscriptAnchor? {
    virtualLayout.viewportAnchor(at: contentOffset.y - transcriptRowsOrigin)
  }

  func restoredViewportTop(from state: SessionScrollState) -> CGFloat? {
    guard let anchor = state.virtualTranscript?.viewportAnchor,
      let rowRelativeTop = virtualLayout.viewportTop(restoring: anchor)
    else { return nil }
    return transcriptRowsOrigin + rowRelativeTop
  }

  func setDistanceFromBottom(
    _ distance: CGFloat,
    synchronizesWithActiveLayoutAnimation: Bool = false
  ) {
    setViewportTop(
      viewportGeometry.offsetY(distanceFromBottom: distance),
      synchronizesWithActiveLayoutAnimation: synchronizesWithActiveLayoutAnimation
    )
  }

  func setViewportTop(
    _ requestedTop: CGFloat,
    synchronizesWithActiveLayoutAnimation: Bool = false
  ) {
    let top = viewportGeometry.boundedOffsetY(requestedTop)
    guard abs(contentOffset.y - top) > 0.25 else { return }
    let mutation = {
      self.setContentOffset(CGPoint(x: 0, y: top), animated: false)
    }
    if synchronizesWithActiveLayoutAnimation {
      applyPositionMutation(mutation)
    } else {
      applyPositionTransaction(mutation)
    }
    lastDistanceFromBottom = currentDistanceFromBottom()
  }

  func applyPositionMutation(_ body: () -> Void) {
    positionApplicationDepth += 1
    defer { positionApplicationDepth -= 1 }
    body()
  }

  func applyPositionTransaction(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    UIView.performWithoutAnimation {
      applyPositionMutation(body)
    }
    CATransaction.commit()
  }

  func applyPendingInitialPositionIfPossible() {
    guard !initialPositionApplied, viewportHeight > 0 else { return }
    let shouldPublishInitialPosition =
      lastStableScrollState == nil
      || (pendingInitialState?.isAtBottom == true && followsLatest)
    let restoredRange = pendingInitialState?.virtualTranscript?.renderedWindow.flatMap {
      virtualLayout.renderedRange(anchorKey: $0.anchorKey, count: $0.count)
    }
    updateMountedRows(rangeOverride: restoredRange)

    if let state = pendingInitialState, !state.isAtBottom {
      if let restoredTop = restoredViewportTop(from: state) {
        setViewportTop(restoredTop)
        lockedRestoreDistance = currentDistanceFromBottom()
      } else {
        if state.distanceFromBottom > viewportGeometry.maximumDistanceFromBottom + 0.5,
          hasOlderHistory
        {
          setViewportTop(viewportGeometry.minimumOffsetY)
          checkForHistoryPrefetch(force: true)
          return
        }
        setDistanceFromBottom(state.distanceFromBottom)
      }
      publishBottomState(currentDistanceFromBottom() <= Self.atBottomThreshold)
    } else {
      lockedRestoreDistance = nil
      setDistanceFromBottom(0)
    }

    initialPositionApplied = true
    pendingInitialState = nil
    lastDistanceFromBottom = currentDistanceFromBottom()
    updateMountedRows(rangeOverride: restoredRange)
    if shouldPublishInitialPosition { emitViewportSnapshot() }
  }

  func updateTopContentInsetIfNeeded() {
    let topInset = max(0, safeAreaInsets.top)
    guard abs(appliedTopContentInset - topInset) > 0.5 else { return }
    let preservedDistance = initialPositionApplied ? currentDistanceFromBottom() : nil
    appliedTopContentInset = topInset
    applyPositionTransaction {
      var inset = contentInset
      inset.top = topInset
      contentInset = inset
      var indicatorInset = verticalScrollIndicatorInsets
      indicatorInset.top = topInset
      verticalScrollIndicatorInsets = indicatorInset
    }
    if let preservedDistance, !isNativeScrollInteractionActive {
      setDistanceFromBottom(preservedDistance)
    }
    lastDistanceFromBottom = currentDistanceFromBottom()
  }

  /// The composer floats over the scroll view, so its height must shorten
  /// only the indicator track. Transcript content keeps its existing bottom
  /// spacer and scroll geometry; this is a visual affordance, not an inset
  /// that participates in positioning or restoration.
  func updateBottomScrollIndicatorInsetIfNeeded(_ rawInset: CGFloat) {
    let bottomInset = max(0, rawInset)
    guard abs(verticalScrollIndicatorInsets.bottom - bottomInset) > 0.5 else { return }
    var indicatorInset = verticalScrollIndicatorInsets
    indicatorInset.bottom = bottomInset
    verticalScrollIndicatorInsets = indicatorInset
  }

  func scrollToBottom() {
    cancelDisclosureViewportAnchor()
    lockedRestoreDistance = nil
    measurementCommitGate.interactionDidEnd()
    commitPendingMeasurements()
    bottomJumpGate.begin()
    setDistanceFromBottom(0)
    updateMountedRows()
    emitViewportSnapshot()
    resolveBottomJumpIfPossible()
  }

  func finishNativeScrollInteraction() {
    if let deferredRowsDuringScroll {
      self.deferredRowsDuringScroll = nil
      applyRows(deferredRowsDuringScroll, layoutFingerprintChanged: false)
      activeRowsRange = deferredActiveRowsRange
      deferredActiveRowsRange = nil
      if let deferredProjectionRevision {
        appliedProjectionRevision = deferredProjectionRevision
        self.deferredProjectionRevision = nil
      }
    }
    commitPendingMeasurements()
    updateMountedRows()
    startPendingSendAnimationIfPossible()
    emitViewportSnapshot()
    checkForHistoryPrefetch()
    acknowledgeOlderHistoryPresentationIfPossible()
  }

  /// The model's response can arrive while UIKit is still dragging or
  /// decelerating. In that case `configure` parks the prepend so native
  /// momentum is uninterrupted. Acknowledge only after the projection that
  /// contains the page is part of the authoritative document geometry.
  func acknowledgeOlderHistoryPresentationIfPossible() {
    guard deferredRowsDuringScroll == nil,
      let target = olderHistoryPresentationTarget,
      let appliedProjectionRevision,
      appliedProjectionRevision >= target.projectionRevision
    else { return }
    olderHistoryPresentationTarget = nil
    onOlderHistoryPresented?(target.token)
  }

  func updatePaginationLoadingIndicator(isPresented: Bool) {
    if isPresented {
      paginationLoadingIndicator.startAnimating()
    } else {
      paginationLoadingIndicator.stopAnimating()
    }
    positionPaginationLoadingIndicator()
  }

  func positionPaginationLoadingIndicator() {
    guard paginationHeaderLayout.reservesSpace else {
      paginationLoadingIndicator.frame = .zero
      return
    }
    paginationLoadingIndicator.sizeToFit()
    let size = paginationLoadingIndicator.bounds.size
    paginationLoadingIndicator.frame = CGRect(
      x: (max(1, bounds.width) - size.width) / 2,
      y: Self.topPadding
        + (paginationHeaderLayout.height - size.height) / 2,
      width: size.width,
      height: size.height
    )
  }

  /// An explicit bottom jump spans more than one layout transaction. Keep
  /// pinning every height correction to distance zero until the complete
  /// destination window is mounted and exact; only then return to ordinary
  /// row anchoring.
  func resolveBottomJumpIfPossible() {
    guard bottomJumpGate.isActive,
      initialPositionApplied,
      viewportHeight > 0
    else { return }
    let requiredKeys = virtualLayout.keys(in: plannedMountedRange())
    let mountedKeys = Set(mountedHosts.keys)
    guard requiredKeys.isSubset(of: mountedKeys) else {
      updateMountedRows()
      return
    }
    let resolvedKeys = TranscriptMountedWindowReadiness.resolvedKeys(
      required: requiredKeys,
      measurements: measurements,
      hosts: mountedHosts
    )
    _ = bottomJumpGate.resolve(
      requiredKeys: requiredKeys,
      resolvedKeys: resolvedKeys,
      hasPendingMeasurements: !pendingMeasurements.isEmpty
    )
  }

  func updateInitialPresentationReadiness() {
    guard !initialPresentationGate.isReady,
      !isDetaching,
      initialPositionApplied,
      viewportHeight > 0
    else { return }

    let requiredKeys = virtualLayout.keys(in: plannedMountedRange())
    let mountedKeys = Set(mountedHosts.keys)
    guard requiredKeys.isSubset(of: mountedKeys) else {
      // Resolving estimates can change which rows intersect the initial
      // viewport. Mount that new window and wait for its measurements
      // instead of revealing an intermediate geometry snapshot.
      updateMountedRows()
      return
    }
    let resolvedKeys = TranscriptMountedWindowReadiness.resolvedKeys(
      required: requiredKeys,
      measurements: measurements,
      hosts: mountedHosts
    )
    guard
      initialPresentationGate.resolve(
        isHydrating: isLoadingInitialHistory || isPreparingInitialProjection,
        isActiveProjectionPending: isAwaitingFirstActiveProjection,
        requiredKeys: requiredKeys,
        resolvedKeys: resolvedKeys,
      )
    else { return }

    applyPositionTransaction {
      if initialBottomPin.isActive {
        setDistanceFromBottom(0)
      }
      initialBottomPin.release()
      canvasView.alpha = 1
      canvasView.accessibilityElementsHidden = false
    }
    isScrollEnabled = true
  }

  func checkForHistoryPrefetch(force: Bool = false) {
    guard presentationRole == .foreground else { return }
    guard hasOlderHistory, let oldestKey = rows.first?.layoutKey else { return }
    let distanceFromTop = viewportGeometry.distanceFromTop(offsetY: contentOffset.y)
    let threshold = max(600, viewportHeight * 1.5)
    historyPrefetchPolicy.requestIfNeeded(
      oldestKey: oldestKey,
      distanceFromTop: distanceFromTop,
      threshold: threshold,
      force: force
    ) { [weak self] in
      self?.onNearTop?() == true
    }
  }

  func emitViewportSnapshot() {
    guard presentationRole == .foreground,
      !isDetaching, initialPositionConfigured, viewportHeight > 0
    else { return }
    let distance = currentDistanceFromBottom()
    publishBottomState(distance <= Self.atBottomThreshold)
    let state = SessionScrollState(
      distanceFromBottom: distance,
      measurementCaches: measurementCache.caches,
      measurementCacheLRU: measurementCache.lru,
      virtualTranscript: currentVirtualRestoreState(
        viewportAnchor: currentViewportAnchor()
      ),
      followMode: followsLatest ? .followingLatest : .staticPosition,
    )
    lastStableScrollState = state
    onViewportChange?(state)
  }

  func republishLastStableScrollState() {
    guard presentationRole == .foreground else { return }
    guard var state = lastStableScrollState else { return }
    state.measurementCaches = measurementCache.caches
    state.measurementCacheLRU = measurementCache.lru
    state.virtualTranscript = currentVirtualRestoreState(
      viewportAnchor: state.virtualTranscript?.viewportAnchor
    )
    lastStableScrollState = state
    onViewportChange?(state)
  }

  func currentVirtualRestoreState(
    viewportAnchor: VirtualTranscriptAnchor?
  ) -> SessionVirtualTranscriptRestoreState {
    let targetKeys = virtualWindowHandoff.targetKeys
    let restoreKeys = targetKeys.isEmpty ? Set(mountedHosts.keys) : targetKeys
    let renderedWindow = virtualLayout.renderedWindow(covering: restoreKeys).map {
      SessionRenderedTranscriptWindow(anchorKey: $0.anchorKey, count: $0.count)
    }
    return SessionVirtualTranscriptRestoreState(
      measurementCacheKey: measurementCache.activeKey,
      rowHeightsByKey: measurements.heightsByKey,
      settledRowsByKey: measurementCache.settledRows,
      renderedWindow: renderedWindow,
      viewportAnchor: viewportAnchor,
    )
  }

  func publishBottomState(_ isAtBottom: Bool) {
    guard presentationRole == .foreground else { return }
    guard lastBottomState != isAtBottom else { return }
    lastBottomState = isAtBottom
    onBottomStateChange?(isAtBottom)
  }
}

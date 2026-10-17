import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  func persistViewport() {
    guard !isDetaching, !isAwaitingWarmProjection,
      initialPositionApplied, !hasPendingViewportResize
    else {
      republishLastStableScrollState()
      return
    }
    emitViewportSnapshot()
  }

  func applyPendingInitialPositionIfPossible() {
    guard !initialPositionApplied, contentView.bounds.height > 0 else { return }

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
        let maximumDistance = max(
          0,
          transcriptDocumentView.frame.height - contentView.bounds.height
        )
        if state.distanceFromBottom > maximumDistance + 0.5, hasOlderHistory {
          setViewportTop(0)
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
    updateMountedRows(rangeOverride: restoredRange)
    if shouldPublishInitialPosition {
      emitViewportSnapshot()
    }
  }

  func currentDistanceFromBottom() -> CGFloat {
    max(0, transcriptDocumentView.frame.height - contentView.bounds.maxY)
  }

  func currentViewportAnchor() -> VirtualTranscriptAnchor? {
    virtualLayout.viewportAnchor(
      at: contentView.bounds.minY - transcriptRowsOrigin
    )
  }

  func restoredViewportTop(from state: SessionScrollState) -> CGFloat? {
    guard let anchor = state.virtualTranscript?.viewportAnchor,
      let rowRelativeTop = virtualLayout.viewportTop(restoring: anchor)
    else { return nil }
    return transcriptRowsOrigin + rowRelativeTop
  }

  func setDistanceFromBottom(_ distance: CGFloat) {
    let viewportHeight = contentView.bounds.height
    let documentHeight = transcriptDocumentView.frame.height
    setViewportTop(max(0, documentHeight - viewportHeight - max(0, distance)))
  }

  func setViewportTop(_ requestedTop: CGFloat) {
    let maximum = max(0, transcriptDocumentView.frame.height - contentView.bounds.height)
    let top = min(max(0, requestedTop), maximum)
    guard abs(contentView.bounds.minY - top) > 0.25 else { return }
    applyPositionTransaction {
      contentView.scroll(to: CGPoint(x: 0, y: top))
      reflectScrolledClipView(contentView)
    }
    lastDistanceFromBottom = currentDistanceFromBottom()
  }

  func applyPositionTransaction(_ body: () -> Void) {
    positionApplicationDepth += 1
    defer {
      positionApplicationDepth -= 1
      if !isApplyingPosition {
        lastObservedViewportTop = contentView.bounds.minY
        publishCurrentViewportGeometry()
      }
    }
    body()
  }

  func layoutViewport(previousSize: CGSize, previousDistance: CGFloat) {
    guard !isDetaching, !isAwaitingWarmProjection else { return }
    let size = contentView.bounds.size
    guard size.width > 0, size.height > 0 else { return }
    guard !isPreparingInitialProjection else { return }
    let widthChanged = abs(size.width - previousSize.width) > 0.5
    let sizeChanged = widthChanged || abs(size.height - previousSize.height) > 0.5
    let shouldPinResize =
      sizeChanged && initialPositionApplied
      && previousSize.width > 0 && previousSize.height > 0
      && lockedRestoreDistance == nil && disclosureViewportAnchor == nil
      && TranscriptViewportResizeAdjustment.resolve(
        previousDistanceFromBottom: followsLatest ? 0 : previousDistance,
        atBottomThreshold: Self.atBottomThreshold,
        isUserInteracting: isHandlingUserInput || isLiveScrolling || isDraggingScrollerKnob
      ) == .pinToBottom
    lastViewportSize = size
    if shouldPinResize, !followsLatest {
      bottomJumpGate.begin()
    }
    if widthChanged {
      _ = activateMeasurementCacheIfNeeded()
      refreshMountedRootViews()
      rebuildDocumentGeometry()
      if inLiveResize { settleMountedRowHeights() }
    } else {
      applyPendingInitialPositionIfPossible()
      updateMountedRows()
    }
    if shouldPinResize {
      setDistanceFromBottom(0)
      updateMountedRows()
    }
    sendTransitions.advance()
    updateInitialPresentationReadiness()
    resolveBottomJumpIfPossible()
  }

  var hasPendingViewportResize: Bool {
    abs(contentView.bounds.width - lastViewportSize.width) > 0.5
      || abs(contentView.bounds.height - lastViewportSize.height) > 0.5
  }

  func publishCurrentViewportGeometry() {
    guard !isDetaching, !isAwaitingWarmProjection, initialPositionApplied,
      contentView.bounds.height > 0
    else { return }
    let distance = currentDistanceFromBottom()
    lastDistanceFromBottom = distance
    if !hasPendingViewportResize {
      lastViewportDistanceFromBottom = distance
    }
    publishBottomState(distance <= Self.atBottomThreshold)
  }

  func scrollToBottom() {
    cancelDisclosureViewportAnchor()
    lockedRestoreDistance = nil
    commitPendingMeasurements()
    bottomJumpGate.begin()
    setDistanceFromBottom(0)
    updateMountedRows()
    emitViewportSnapshot()
    resolveBottomJumpIfPossible()
  }

  func viewportDidScroll() {
    guard !isDetaching, !isAwaitingWarmProjection else { return }
    if hasPendingViewportResize {
      needsLayout = true
      return
    }
    guard !isApplyingPosition else { return }
    let previousDistance = lastDistanceFromBottom
    let distance = currentDistanceFromBottom()
    lastDistanceFromBottom = distance
    let viewportTop = contentView.bounds.minY
    let isUserMovement = isDraggingScrollerKnob || isHandlingUserInput || isLiveScrolling
    if let lastObservedViewportTop, isUserMovement {
      pendingWindowScrollDelta += viewportTop - lastObservedViewportTop
      runwayMotion.observe(
        viewportTop: viewportTop,
        timestamp: CACurrentMediaTime()
      )
    } else if !isApplyingPosition {
      pendingWindowScrollDelta = 0
      if runwayMotion.pointsPerSecond == 0 {
        runwayMotion.reset(
          viewportTop: viewportTop,
          timestamp: CACurrentMediaTime()
        )
      }
    }
    lastObservedViewportTop = viewportTop
    if isDraggingScrollerKnob || isHandlingUserInput || isLiveScrolling {
      requestMountedRowsUpdate()
    } else {
      updateMountedRows()
    }
    layoutMountedTextViewportsIfNeeded()

    let atBottom = distance <= Self.atBottomThreshold
    let isRecentUserMovement =
      isHandlingUserInput || isLiveScrolling
      || ProcessInfo.processInfo.systemUptime <= userInputDeadline
    if !isApplyingPosition, isRecentUserMovement, !atBottom,
      distance > previousDistance + 0.5, followsLatest
    {
      followsLatest = false
      onFollowStateChange?(false)
    } else if !isApplyingPosition, isRecentUserMovement, atBottom, !followsLatest {
      followsLatest = true
      onFollowStateChange?(true)
    }
    publishCurrentViewportGeometry()
    updateCollapsibleEarlierHistory()

    if !isApplyingPosition, isHandlingUserInput || isLiveScrolling {
      lockedRestoreDistance = nil
      if !isLiveScrolling {
        emitViewportSnapshot()
      }
    }
    checkForHistoryPrefetch()
  }

  func markRecentUserInput() {
    userInputDeadline = ProcessInfo.processInfo.systemUptime + 0.35
  }

  func publishBottomState(_ isAtBottom: Bool) {
    guard lastBottomState != isAtBottom else { return }
    lastBottomState = isAtBottom
    onBottomStateChange?(isAtBottom)
  }

  func checkForHistoryPrefetch(force: Bool = false) {
    guard hasOlderHistory, let oldestKey = rows.first?.layoutKey else { return }
    let distanceFromTop = contentView.bounds.minY
    let threshold = max(600, contentView.bounds.height * 1.5)
    historyPrefetchPolicy.requestIfNeeded(
      oldestKey: oldestKey,
      distanceFromTop: distanceFromTop,
      threshold: threshold,
      force: force
    ) { [weak self] in
      self?.onNearTop?() == true
    }
  }

  func resolveBottomJumpIfPossible() {
    guard bottomJumpGate.isActive,
      initialPositionApplied,
      contentView.bounds.height > 0
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
      hasPendingMeasurements: !pendingMeasuredHeights.isEmpty
    )
  }

  func updateInitialPresentationReadiness() {
    guard !initialPresentationGate.isReady,
      !isDetaching,
      initialPositionApplied,
      contentView.bounds.height > 0
    else { return }

    let requiredKeys = virtualLayout.keys(in: plannedMountedRange())
    let mountedKeys = Set(mountedHosts.keys)
    guard requiredKeys.isSubset(of: mountedKeys) else {
      requestMountedRowsUpdate()
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
        hasPendingMeasurements: !pendingMeasuredHeights.isEmpty
      )
    else { return }

    presentInitialTranscript()
  }

  func presentInitialTranscript() {
    applyPositionTransaction {
      if initialBottomPin.isActive {
        setDistanceFromBottom(0)
      }
      initialBottomPin.release()
      transcriptDocumentView.alphaValue = 1
      transcriptDocumentView.setAccessibilityHidden(false)
      verticalScroller?.isEnabled = true
    }
    onInitialPresentationReady?()
  }

  func updatePaginationLoadingIndicator(isPresented: Bool) {
    if isPresented {
      paginationLoadingIndicator.startAnimation(nil)
    } else {
      paginationLoadingIndicator.stopAnimation(nil)
    }
    positionPaginationLoadingIndicator()
  }

  func positionPaginationLoadingIndicator() {
    guard paginationHeaderLayout.reservesSpace else {
      paginationLoadingIndicator.frame = .zero
      return
    }
    paginationLoadingIndicator.sizeToFit()
    let size = paginationLoadingIndicator.frame.size
    paginationLoadingIndicator.frame = CGRect(
      x: (max(1, contentView.bounds.width) - size.width) / 2,
      y: Self.topPadding
        + (paginationHeaderLayout.height - size.height) / 2,
      width: size.width,
      height: size.height
    )
  }

  func emitViewportSnapshot() {
    TranscriptPerformanceTrace.record(
      "macos.viewport",
      values: [
        "distance": Double(currentDistanceFromBottom()),
        "anchor": currentViewportAnchor().map { Double($0.key.hashValue & 0x1fffffffffffff) } ?? -1,
        "anchorOffset": currentViewportAnchor().map { Double($0.offsetFromRowTop) } ?? -1,
        "follow": followsLatest ? 1 : 0,
        "ready": initialPresentationGate.isReady ? 1 : 0,
      ])

    guard !isDetaching, !isAwaitingWarmProjection,
      initialPositionConfigured, initialPositionApplied,
      contentView.bounds.height > 0
    else { return }
    let distance = currentDistanceFromBottom()
    let atBottom = distance <= Self.atBottomThreshold
    publishBottomState(atBottom)
    let state = SessionScrollState(
      distanceFromBottom: distance,
      measurementCaches: measurementCache.caches,
      measurementCacheLRU: measurementCache.lru,
      virtualTranscript: currentVirtualRestoreState(
        viewportAnchor: currentViewportAnchor()
      ),
      followMode: followsLatest ? .followingLatest : .staticPosition
    )
    lastStableScrollState = state
    viewportSnapshotGeneration &+= 1
    onViewportChange?(state)
  }

  func republishLastStableScrollState() {
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
      viewportAnchor: viewportAnchor
    )
  }
}

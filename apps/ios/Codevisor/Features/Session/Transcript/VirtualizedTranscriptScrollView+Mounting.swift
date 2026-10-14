import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

extension VirtualizedTranscriptScrollView {
  func plannedMountedRange(scrollDelta: CGFloat = 0) -> Range<Int> {
    windowPlanner.plannedRange(
      layout: virtualLayout,
      distanceFromBottom: currentDistanceFromBottom(),
      viewportHeight: viewportHeight,
      scrollDelta: scrollDelta,
      isInitialPresentationReady: initialPresentationGate.isReady,
      currentTargetKeys: virtualWindowHandoff.targetKeys
    )
  }

  func updateMountedRows(rangeOverride: Range<Int>? = nil) {
    let traceStart = TranscriptPerformanceTrace.begin()
    defer {
      surfaceController.recordPerformanceTrace(
        "ios.mount", since: traceStart,
        hostCount: mountedHosts.count, distance: currentDistanceFromBottom())
    }

    guard initialPositionApplied || viewportHeight > 0,
      let hostingParent
    else { return }
    virtualWindowHandoff.retainOnlyValidKeys { rowByKey[$0] != nil }
    let scrollDelta = rangeOverride == nil ? pendingWindowScrollDelta : 0
    pendingWindowScrollDelta = 0
    let targetRange: Range<Int>
    if let rangeOverride {
      targetRange = rangeOverride
    } else {
      targetRange = plannedMountedRange(scrollDelta: scrollDelta)
    }
    let visibleRange = virtualLayout.visibleRange(
      distanceFromBottom: currentDistanceFromBottom(),
      viewportHeight: viewportHeight,
      overscanCount: 0,
    )
    virtualWindowHandoff.setTarget(
      TranscriptWindowPlanner.targetKeys(
        layout: virtualLayout,
        targetRange: targetRange,
        visibleRange: visibleRange
      )
    )

    let mountPlan = virtualWindowPolicy.mountPlan(
      targetRange: targetRange,
      visibleRange: visibleRange,
      scrollDelta: scrollDelta,
    )
    let mountStarted = CACurrentMediaTime()
    for index in mountPlan.visibleIndices {
      mountRow(
        at: index,
        parent: hostingParent,
        requiresImmediatePresentation: true
      )
    }
    assert(
      mountPlan.visibleIndices.allSatisfy { index in
        guard virtualLayout.keys.indices.contains(index) else { return false }
        return mountedHosts[virtualLayout.keys[index]] != nil
      },
      "Loaded transcript viewport must be fully mounted"
    )

    for index in mountPlan.runwayIndices {
      guard virtualLayout.keys.indices.contains(index) else { continue }
      let key = virtualLayout.keys[index]
      guard mountedHosts[key] == nil else { continue }
      guard presentationDisplayLink == nil || remainingMountsThisFrame > 0 else { break }
      if presentationDisplayLink != nil,
        CACurrentMediaTime() - mountStarted >= mountWorkBudget
      {
        break
      }
      if mountRow(
        at: index,
        parent: hostingParent,
        requiresImmediatePresentation: false
      ), presentationDisplayLink != nil {
        remainingMountsThisFrame -= 1
      }
    }
    removeMountedHosts(excluding: virtualWindowHandoff.retainedKeys)
    promoteTargetWindowIfReady()
    if presentationDisplayLink != nil,
      virtualWindowHandoff.targetKeys.contains(where: { mountedHosts[$0] == nil })
    {
      requestMountedRowsUpdate()
    }
  }

  @discardableResult
  func mountRow(
    at index: Int,
    parent: UIViewController,
    requiresImmediatePresentation: Bool
  ) -> Bool {
    guard virtualLayout.keys.indices.contains(index) else { return false }
    let key = virtualLayout.keys[index]
    if let host = mountedHosts[key] {
      if requiresImmediatePresentation, !host.isPresentationReady,
        key != deferredActivePlaceholderKey
      {
        host.prepareForImmediatePresentation()
      }
      return false
    }
    guard let row = rowByKey[key] else { return false }

    let host = parkedHosts.take(for: key) ?? TranscriptRowHost(parent: parent)
    host.prepareForMountedRow()
    host.onMeasuredHeight = { [weak self] measurement in
      self?.recordMeasuredHeight(measurement)
    }
    canvasView.addSubview(host)
    mountedHosts[key] = host
    position(host: host, at: index)
    host.syncContentWidth()
    if defersActivePlaceholderPresentation(for: row) {
      deferredActivePlaceholderKey = key
      host.install(
        row: row,
        rootView: AnyView(Color.clear.frame(height: row.estimatedHeight)),
        force: true
      )
      return true
    }
    host.install(
      row: row,
      rootView: measuredRootView(for: row),
      force: host.representedRow == nil,
    )
    if requiresImmediatePresentation {
      host.prepareForImmediatePresentation()
    }
    sendTransitions.hostDidMount(host, key: key)
    return true
  }

  func defersActivePlaceholderPresentation(for row: TranscriptVirtualRow) -> Bool {
    guard case .active = row.id else { return false }
    return isAwaitingFirstActiveProjection && !initialPresentationGate.isReady
  }

  func presentDeferredActivePlaceholderIfNeeded() {
    guard let key = deferredActivePlaceholderKey, !isAwaitingFirstActiveProjection else { return }
    deferredActivePlaceholderKey = nil
    guard let row = rowByKey[key], let host = mountedHosts[key] else { return }
    host.install(row: row, rootView: measuredRootView(for: row), force: true)
    host.resetReportedContentHeight()
    host.prepareForImmediatePresentation()
  }

  func promoteTargetWindowIfReady() {
    guard
      virtualWindowHandoff.promoteIfReady({ key in
        TranscriptMountedWindowReadiness.isPromotable(
          key: key,
          measurements: measurements,
          hasPendingMeasurement: pendingMeasurements[key] != nil,
          host: mountedHosts[key]
        )
      })
    else { return }
    removeMountedHosts(excluding: virtualWindowHandoff.retainedKeys)
  }

  func removeMountedHosts(excluding retainedKeys: Set<String>) {
    guard !sendTransitions.isAnimatingRows else {
      requestMountedRowsUpdateAfterSendTransition()
      return
    }
    let obsoleteKeys = mountedHosts.keys.filter { !retainedKeys.contains($0) }
    removeMountedHosts(withKeys: obsoleteKeys)
  }

  func removeDeletedMountedHosts(
    previousRowsByKey: [String: TranscriptVirtualRow]
  ) {
    let deletedMountedKeys = previousRowsByKey.keys.filter {
      rowByKey[$0] == nil && mountedHosts[$0] != nil
    }
    removeMountedHosts(withKeys: deletedMountedKeys)
  }

  func removeMountedHosts(withKeys obsoleteKeys: [String]) {
    for key in obsoleteKeys {
      guard let host = mountedHosts.removeValue(forKey: key) else { continue }
      host.removeFromSuperview()
      park(host, for: key)
    }
    assert(mountedHosts.keys.allSatisfy { rowByKey[$0] != nil })
  }

  func park(_ host: TranscriptRowHost, for key: String) {
    guard rowByKey[key] != nil else {
      host.detachFromParent()
      return
    }
    parkedHosts.insert(host, for: key)
  }

  func evictChangedParkedHosts(
    previousRowsByKey: [String: TranscriptVirtualRow],
  ) {
    parkedHosts.remove { key in
      guard let row = rowByKey[key] else { return true }
      return previousRowsByKey[key]?.content != row.content
        || previousRowsByKey[key]?.measurementRevision != row.measurementRevision
    }
  }

  func refreshMountedRootViews() {
    for (key, host) in mountedHosts {
      guard let row = rowByKey[key], key != deferredActivePlaceholderKey else { continue }
      host.install(row: row, rootView: measuredRootView(for: row), force: true)
    }
  }

  func refreshChangedMountedRootViews(
    previousRowsByKey: [String: TranscriptVirtualRow],
  ) {
    for (key, host) in mountedHosts {
      guard key != deferredActivePlaceholderKey,
        let row = rowByKey[key], let previous = previousRowsByKey[key],
        previous.content != row.content
          || previous.measurementRevision != row.measurementRevision
      else { continue }
      host.install(row: row, rootView: measuredRootView(for: row), force: true)
    }
  }

  func positionMountedRows() {
    for (key, host) in mountedHosts {
      guard let index = virtualLayout.indexByKey[key] else { continue }
      position(host: host, at: index)
    }
  }

  func position(host: TranscriptRowHost, at index: Int) {
    guard virtualLayout.keys.indices.contains(index) else { return }
    let viewportWidth = max(1, bounds.width)
    let availableWidth = max(1, viewportWidth - Self.horizontalPadding * 2)
    let rowWidth = min(Self.maxRowWidth, availableWidth)
    let rowX = max(Self.horizontalPadding, (viewportWidth - rowWidth) / 2)
    let nextFrame = CGRect(
      x: rowX,
      y: paginationHeaderLayout.rowOrigin(
        topPadding: Self.topPadding,
        rowOffset: virtualLayout.frame(at: index).minY
      ),
      width: rowWidth,
      height: virtualLayout.frame(at: index).height,
    )
    if host.frame != nextFrame {
      host.frame = nextFrame
    }
    host.syncContentWidth()
  }
}

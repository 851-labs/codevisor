import AppKit
import MarkdownCore
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  func plannedMountedRange(scrollDelta: CGFloat = 0) -> Range<Int> {
    windowPlanner.plannedRange(
      layout: virtualLayout,
      distanceFromBottom: currentDistanceFromBottom(),
      viewportHeight: contentView.bounds.height,
      scrollDelta: scrollDelta,
      isInitialPresentationReady: initialPresentationGate.isReady,
      currentTargetKeys: virtualWindowHandoff.targetKeys
    )
  }

  func updateMountedRows(rangeOverride: Range<Int>? = nil) {
    let traceStart = TranscriptPerformanceTrace.begin()
    defer {
      surfaceController.recordPerformanceTrace(
        "macos.mount", since: traceStart,
        hostCount: mountedHosts.count, distance: currentDistanceFromBottom())
    }

    guard initialPositionApplied || contentView.bounds.height > 0 else { return }
    guard !isUpdatingMountedRows else {
      deferMountedRowsUpdateUntilLayoutCompletes(rangeOverride: rangeOverride)
      return
    }
    isUpdatingMountedRows = true
    defer { isUpdatingMountedRows = false }
    let reconciliation = reconcileVirtualWindow(rangeOverride: rangeOverride)
    let mountPlan = reconciliation.mountPlan
    let usesFrameBudget = presentationDisplayLink != nil && !inLiveResize
    let budgetsInitialWindow = usesFrameBudget && !initialPresentationGate.isReady
    if budgetsInitialWindow, initialMountWorkStartedAt == nil {
      initialMountWorkStartedAt = mountWorkTime()
    }
    let mountStarted = budgetsInitialWindow ? initialMountWorkStartedAt! : mountWorkTime()
    mountViewportRows(
      at: mountPlan.visibleIndices,
      budgetsInitialWindow: budgetsInitialWindow,
      workStartedAt: mountStarted
    )

    prepareRunwayRowsEndToEnd(
      at: mountPlan.runwayIndices,
      workStartedAt: mountStarted,
      usesFrameBudget: usesFrameBudget
    )
    if reconciliation.targetChanged {
      retireMountedHosts(excluding: virtualWindowHandoff.retainedKeys)
    }
    promoteTargetWindowAndRetireIfReady()
    let needsRunwayPreparation =
      canPrepareRunwayRows
      && virtualWindowHandoff.targetKeys.contains { key in
        mountedHosts[key]?.needsRunwayPreparation == true
      }
    if usesFrameBudget,
      virtualWindowHandoff.targetKeys.contains(where: { mountedHosts[$0] == nil })
        || needsRunwayPreparation
    {
      requestMountedRowsUpdate()
    }
    refreshSelectionHighlightsIfNeeded()
    refreshFindHighlightsIfNeeded()
  }

  func reconcileVirtualWindow(
    rangeOverride: Range<Int>?
  ) -> (mountPlan: TranscriptVirtualWindowMountPlan, targetChanged: Bool) {
    virtualWindowHandoff.retainOnlyValidKeys { rowByKey[$0] != nil }
    let observedScrollDelta = rangeOverride == nil ? pendingWindowScrollDelta : 0
    pendingWindowScrollDelta = 0
    let projectedScrollDelta =
      rangeOverride == nil
      ? runwayMotion.projectedDelta(
        timestamp: CACurrentMediaTime(),
        maximumDistance: contentView.bounds.height * 3
      )
      : 0
    let scrollDelta =
      abs(projectedScrollDelta) > abs(observedScrollDelta)
      ? projectedScrollDelta
      : observedScrollDelta
    let targetRange = rangeOverride ?? plannedMountedRange(scrollDelta: scrollDelta)
    let visibleRange = virtualLayout.visibleRange(
      distanceFromBottom: currentDistanceFromBottom(),
      viewportHeight: contentView.bounds.height,
      overscanCount: 0
    )
    let targetKeys = TranscriptWindowPlanner.targetKeys(
      layout: virtualLayout,
      targetRange: targetRange,
      visibleRange: visibleRange
    )
    let targetChanged = targetKeys != virtualWindowHandoff.targetKeys
    if targetChanged {
      virtualWindowHandoff.setTarget(targetKeys)
    }
    return (
      virtualWindowPolicy.mountPlan(
        targetRange: targetRange,
        visibleRange: visibleRange,
        scrollDelta: scrollDelta
      ),
      targetChanged
    )
  }

  func prepareRunwayRowsEndToEnd(
    at indices: [Int],
    workStartedAt: CFTimeInterval,
    usesFrameBudget: Bool
  ) {
    for index in indices {
      if usesFrameBudget,
        remainingMountsThisFrame == 0,
        remainingRunwayPreparationsThisFrame == 0
      {
        break
      }
      guard virtualLayout.keys.indices.contains(index) else { continue }
      if usesFrameBudget,
        mountWorkTime() - workStartedAt >= mountWorkBudget
      {
        break
      }
      let key = virtualLayout.keys[index]
      if mountedHosts[key] == nil {
        guard !usesFrameBudget || remainingMountsThisFrame > 0 else {
          continue
        }
        if mountRow(at: index, requiresImmediatePresentation: false), usesFrameBudget {
          remainingMountsThisFrame -= 1
        }
      }
      guard let host = mountedHosts[key], host.needsRunwayPreparation else { continue }
      guard canPrepareRunwayRows else { continue }
      guard !usesFrameBudget || remainingRunwayPreparationsThisFrame > 0 else {
        continue
      }
      host.prepareForImmediatePresentation()
      if usesFrameBudget { remainingRunwayPreparationsThisFrame -= 1 }
    }
  }

  @discardableResult
  func mountRow(
    at index: Int,
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
    if usesNativeMarkdownHost(for: row) {
      return mountMarkdownRow(
        row,
        at: index,
        requiresImmediatePresentation: requiresImmediatePresentation
      )
    }

    let host = hostPool.takeHostedRow() ?? TranscriptRowHost(frame: .zero)
    host.prepareForMountedRow()
    observeRowPresentation(host, for: key)
    transcriptDocumentView.addSubview(host)
    mountedHosts[key] = host
    position(host: host, at: index)
    host.syncContentWidth()
    if defersActivePlaceholderPresentation(for: row) {
      deferredActivePlaceholderKey = key
      host.installRootView(
        AnyView(Color.clear.frame(height: row.estimatedHeight)),
        knownHeight: row.estimatedHeight
      )
      return true
    }
    let rootView = measuredRootView(for: row)
    let knownHeight: CGFloat? =
      if row.id.isCacheableSettledRow,
        let measuredHeight = measurements[key],
        !measurements.isStale(key)
      {
        measuredHeight
      } else {
        nil
      }
    host.installRootView(rootView, knownHeight: knownHeight)
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
    guard rowByKey[key] != nil, mountedHosts[key] != nil else { return }
    replaceMountedHost(for: key)
  }

  func usesNativeMarkdownHost(for row: TranscriptVirtualRow) -> Bool {
    guard case let .markdownChunk(chunk) = row.content else { return false }
    return chunk.lifecycle == .settled && !MarkdownLayoutPolicy.requiresBackgroundTextLayout(chunk.blocks)
  }

  func mountMarkdownRow(
    _ row: TranscriptVirtualRow,
    at index: Int,
    requiresImmediatePresentation: Bool
  ) -> Bool {
    guard case let .markdownChunk(chunk) = row.content else { return false }
    let key = row.layoutKey
    let host: TranscriptMarkdownRowHost
    if let prepared = markdownHostCache.take(for: key) {
      host = prepared
    } else if let recycled = hostPool.takeMarkdownRow() {
      host = recycled
    } else {
      host = TranscriptMarkdownRowHost(frame: .zero)
    }

    host.prepareForMountedRow()
    host.onHeightChange = { [weak self] height in
      self?.recordMeasuredHeight(height, for: key)
    }
    transcriptDocumentView.addSubview(host)
    mountedHosts[key] = host
    position(host: host, at: index)
    let knownHeight: CGFloat? =
      if let measuredHeight = measurements[key], !measurements.isStale(key) {
        measuredHeight
      } else {
        nil
      }
    host.setContent(
      chunk,
      streamID: key,
      style: markdownRowStyle,
      linkAction: markdownLinkAction,
      imageLoader: markdownImageLoader,
      knownHeight: knownHeight
    )
    if requiresImmediatePresentation, !host.isPresentationReady {
      host.prepareForImmediatePresentation()
    }
    sendTransitions.hostDidMount(host, key: key)
    return true
  }

  func promoteTargetWindowIfReady() -> Bool {
    guard virtualWindowHandoff.presentedKeys != virtualWindowHandoff.targetKeys else {
      return false
    }
    return virtualWindowHandoff.promoteIfReady { key in
      TranscriptMountedWindowReadiness.isPromotable(
        key: key,
        measurements: measurements,
        hasPendingMeasurement: pendingMeasuredHeights[key] != nil,
        host: mountedHosts[key]
      )
    }
  }

  @discardableResult
  func promoteTargetWindowAndRetireIfReady() -> Bool {
    let promoted = promoteTargetWindowIfReady()
    guard promoted else { return false }
    retireMountedHosts(excluding: virtualWindowHandoff.retainedKeys)
    return true
  }

  func retireMountedHosts(excluding retainedKeys: Set<String>) {
    guard !sendTransitions.isAnimatingRows else {
      requestMountedRowsUpdateAfterSendTransition()
      return
    }
    let obsoleteKeys = mountedHosts.keys.filter { !retainedKeys.contains($0) }
    retireMountedHosts(withKeys: obsoleteKeys)
  }

  func retireRemovedMountedHosts(
    previousRowsByKey: [String: TranscriptVirtualRow]
  ) {
    let removedMountedKeys = previousRowsByKey.keys.filter {
      rowByKey[$0] == nil && mountedHosts[$0] != nil
    }
    let automaticSections = automaticallyCollapsedWorkedSections(
      previousRowsByKey: previousRowsByKey
    )
    let automaticGroups = Dictionary(grouping: removedMountedKeys) { key in
      previousRowsByKey[key]?.workedSection?.identity
    }.compactMap { identity, keys -> [String]? in
      guard let identity, automaticSections.contains(identity),
        keys.contains(where: { key in
          previousRowsByKey[key]?.workedSection?.role == .content
        })
      else { return nil }
      return keys.filter {
        previousRowsByKey[$0]?.workedSection?.role == .content
      }
    }.filter(canAnimateDisclosureCollapse)
    let animatedKeys = Set(automaticGroups.flatMap { $0 })

    if !animatedKeys.isEmpty {
      if !followsLatest {
        beginDisclosureViewportAnchor()
      }
      pendingDisclosureCollapseOrigins = Dictionary(
        uniqueKeysWithValues: mountedHosts.compactMap { key, host in
          guard !animatedKeys.contains(key) else { return nil }
          return (key, presentedOriginY(for: host) - contentView.bounds.minY)
        }
      )
      for keys in automaticGroups {
        startAutomaticDisclosureCollapse(keys: keys)
      }
    }
    retireMountedHosts(withKeys: removedMountedKeys.filter { !animatedKeys.contains($0) })
  }

  func retireMountedHosts(withKeys obsoleteKeys: [String]) {
    guard !obsoleteKeys.isEmpty else { return }
    for key in obsoleteKeys {
      guard let host = mountedHosts.removeValue(forKey: key) else { continue }
      host.removeFromSuperviewWithoutNeedingDisplay()
      storeDetachedHost(host, for: key)
    }
    assert(mountedHosts.keys.allSatisfy { rowByKey[$0] != nil })
    if hostPool.hasRetiringHosts { requestDisplayFrame() }
  }

  func storeDetachedHost(_ host: TranscriptMountedRowHost, for key: String) {
    selectionHostWillDetach(host, key: key)
    findHostWillDetach(host, key: key)
    host.onHeightChange = nil
    host.onPresentationReady = nil
    host.layer?.removeAnimation(forKey: Self.disclosureExitAnimationKey)
    host.layer?.removeAnimation(forKey: Self.disclosureCollapseAnimationKey)
    host.layer?.opacity = 1
    host.setAccessibilityHidden(false)
    if let markdownHost = host as? TranscriptMarkdownRowHost {
      let evicted = markdownHostCache.insert(
        markdownHost,
        for: key,
        height: host.frame.height,
        maximumTotalHeight: max(1, contentView.bounds.height * 12)
      )
      hostPool.recycle(evicted)
    } else if let hosted = host as? TranscriptRowHost {
      hostPool.retire(hosted)
    }
  }

  func refreshMountedRootViews() {
    refreshMountedHosts(previousRowsByKey: nil)
  }

  func refreshChangedMountedRootViews(
    previousRowsByKey: [String: TranscriptVirtualRow]
  ) {
    refreshMountedHosts(previousRowsByKey: previousRowsByKey)
  }

  func refreshMountedHosts(
    previousRowsByKey: [String: TranscriptVirtualRow]?
  ) {
    var replacementKeys: [String] = []
    for (key, host) in mountedHosts {
      guard let row = rowByKey[key] else { continue }
      if key == deferredActivePlaceholderKey { continue }
      if let previousRowsByKey {
        guard let previous = previousRowsByKey[key],
          previous.content != row.content
            || previous.measurementRevision != row.measurementRevision
        else { continue }
      }

      let wantsNativeMarkdown = usesNativeMarkdownHost(for: row)
      let isNativeMarkdown = host is TranscriptMarkdownRowHost
      let preservesLiveMarkdownHost = preservesLiveMarkdownHost(
        host: host,
        previous: previousRowsByKey?[key],
        current: row
      )
      guard wantsNativeMarkdown == isNativeMarkdown || preservesLiveMarkdownHost else {
        invalidateMeasurementForRendererTransition(key)
        replacementKeys.append(key)
        continue
      }

      if let markdownHost = host as? TranscriptMarkdownRowHost,
        case let .markdownChunk(chunk) = row.content
      {
        let knownHeight: CGFloat? =
          if let height = measurements[key], !measurements.isStale(key) {
            height
          } else {
            nil
          }
        markdownHost.setContent(
          chunk,
          streamID: key,
          style: markdownRowStyle,
          linkAction: markdownLinkAction,
          imageLoader: markdownImageLoader,
          knownHeight: knownHeight
        )
      } else if let hosted = host as? TranscriptRowHost {
        hosted.rootView = measuredRootView(for: row)
      }
    }

    for key in replacementKeys {
      replaceMountedHost(for: key)
    }
    refreshSelectionHighlightsIfNeeded()
    refreshFindHighlightsIfNeeded()
  }

  func preservesLiveMarkdownHost(
    host: TranscriptMountedRowHost,
    previous: TranscriptVirtualRow?,
    current: TranscriptVirtualRow
  ) -> Bool {
    guard host is TranscriptRowHost,
      case let .markdownChunk(previousChunk) = previous?.content,
      case let .markdownChunk(currentChunk) = current.content
    else { return false }
    return previousChunk.lifecycle == .receiving
      && currentChunk.lifecycle == .settled
  }

  func replaceMountedHost(for key: String) {
    guard let host = mountedHosts.removeValue(forKey: key),
      let index = virtualLayout.indexByKey[key]
    else { return }
    let visibleDocumentRect = NSRect(
      x: 0,
      y: contentView.bounds.minY,
      width: transcriptDocumentView.bounds.width,
      height: contentView.bounds.height
    )
    let requiresImmediatePresentation = host.frame.intersects(visibleDocumentRect)
    host.removeFromSuperviewWithoutNeedingDisplay()
    storeDetachedHost(host, for: key)
    _ = mountRow(
      at: index,
      requiresImmediatePresentation: requiresImmediatePresentation
    )
  }

}

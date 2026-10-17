import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  func invalidateChangedMeasurements(
    previousRowsByKey: [String: TranscriptVirtualRow],
    newRows: [TranscriptVirtualRow]
  ) {
    for row in newRows {
      guard row.id.isCacheableSettledRow else { continue }
      let key = row.layoutKey
      if let previous = previousRowsByKey[key] {
        guard previous.measurementRevision != row.measurementRevision else { continue }
      } else {
        guard measurements[key] != nil, !measurements.isStale(key) else { continue }
        measurements.markStale(key)
        continue
      }
      measurements.markStale(key)
      measurementCache.removeMeasurement(for: key)
    }
  }

  @discardableResult
  func activateMeasurementCacheIfNeeded() -> Bool {
    guard contentView.bounds.width > 0 else { return false }
    let key = SessionMeasurementCacheKey(
      rowWidthHalfPoints: Int((effectiveRowWidth * 2).rounded()),
      layoutFingerprint: layoutFingerprint
    )
    guard key != measurementCache.activeKey else { return false }

    let cached = measurementCache.activate(key)

    let provisionalMountedHeights = Dictionary(
      uniqueKeysWithValues: mountedHosts.keys.compactMap { key in
        measurements[key].map { (key, $0) }
      })
    measurements.removeAll(keepingCapacity: true)
    var valid: [String: SessionMeasuredRow] = [:]
    valid.reserveCapacity(cached.count)
    for row in rows {
      let rowKey = row.layoutKey
      guard row.id.isCacheableSettledRow,
        let measurement = cached[rowKey],
        measurement.revision == row.measurementRevision,
        measurement.height > 0
      else { continue }
      valid[rowKey] = measurement
      measurements.setExact(measurement.height, for: rowKey)
    }
    measurementCache.replaceActiveMeasurements(valid)
    for row in rows {
      if case let .bottomSpacer(height) = row.content {
        measurements.setExact(height, for: row.layoutKey)
      }
    }
    for (key, height) in provisionalMountedHeights where measurements[key] == nil {
      measurements.setProvisional(height, for: key)
    }
    if let restore = pendingInitialState?.virtualTranscript,
      restore.measurementCacheKey == key
    {
      for (rowKey, height) in restore.rowHeightsByKey where height > 0 {
        guard let row = rowByKey[rowKey] else { continue }
        if row.id.isCacheableSettledRow {
          guard
            restore.settledRowsByKey[rowKey]?.revision
              == row.measurementRevision
          else { continue }
        }
        measurements.setProvisional(height, for: rowKey)
      }
    }
    return true
  }

  func rebuildDocumentGeometry(changedHeights: [String: CGFloat]? = nil) {
    let traceStart = TranscriptPerformanceTrace.begin()
    defer {
      surfaceController.recordPerformanceTrace(
        "macos.geometry", since: traceStart,
        hostCount: mountedHosts.count, distance: currentDistanceFromBottom())
    }

    let previousLayout = virtualLayout
    let previousDistance = initialPositionApplied ? currentDistanceFromBottom() : nil
    let plan = TranscriptGeometryRebuildPlan(
      previousLayout: previousLayout,
      previousDistanceFromBottom: previousDistance,
      viewportHeight: contentView.bounds.height,
      followsLatest: followsLatest,
      lockedRestoreDistance: lockedRestoreDistance,
      initialPositionApplied: initialPositionApplied,
      gatePinsBottom: bottomJumpGate.isActive || initialBottomPin.isActive,
      bottomSpacerWillChange: TranscriptDocumentGeometry.bottomSpacerGeometryWillChange(
        from: previousLayout,
        spacerRow: rowByKey[TranscriptVirtualRow.ID.bottomSpacer.layoutKey],
        measurements: measurements
      ),
      atBottomThreshold: Self.atBottomThreshold,
      measurements: measurements
    )
    var initialRestoreRange: Range<Int>?
    applyPositionTransaction {
      virtualLayout =
        TranscriptDocumentGeometry.incrementallyUpdatedLayout(
          virtualLayout,
          rowCount: rows.count,
          changedHeights: changedHeights
        )
        ?? TranscriptDocumentGeometry.layout(
          rows: rows,
          measurements: measurements,
          spacing: Self.rowSpacing
        )
      initialRestoreRange = pendingInitialState?.virtualTranscript?.renderedWindow.flatMap {
        virtualLayout.renderedRange(anchorKey: $0.anchorKey, count: $0.count)
      }

      let width = max(1, contentView.bounds.width)
      transcriptDocumentView.frame = CGRect(
        x: 0,
        y: 0,
        width: width,
        height: paginationHeaderLayout.documentHeight(
          topPadding: Self.topPadding,
          rowsHeight: virtualLayout.totalHeight
        )
      )
      positionPaginationLoadingIndicator()
      let firstChangedIndex = changedHeights?.keys.compactMap {
        virtualLayout.indexByKey[$0]
      }.min()
      positionMountedRows(startingAt: firstChangedIndex)

      if !initialPositionApplied {
        applyPendingInitialPositionIfPossible()
      } else if let anchor = disclosureViewportAnchor {
        if let row = anchor.row, let index = virtualLayout.indexByKey[row.key] {
          setViewportTop(rowFrame(at: index).minY - row.viewportOffset)
        } else {
          setViewportTop(anchor.viewportTop)
        }
      } else if let resolvedDistance = plan.resolvedDistanceFromBottom(
        newLayout: virtualLayout,
        previousLayout: previousLayout
      ) {
        if lockedRestoreDistance != nil {
          lockedRestoreDistance = resolvedDistance
        }
        setDistanceFromBottom(resolvedDistance)
      }
      animatePendingDisclosureCollapse()
      lastDistanceFromBottom = currentDistanceFromBottom()
    }
    if initialRestoreRange != nil || changedHeights == nil || mountedCoverageNeedsUpdate() {
      updateMountedRows(rangeOverride: initialRestoreRange)
    }
    layoutMountedTextViewportsIfNeeded()
    updateInitialPresentationReadiness()
    resolveBottomJumpIfPossible()
    updateCollapsibleEarlierHistory()
  }

  func mountedCoverageNeedsUpdate() -> Bool {
    let targetRange = plannedMountedRange()
    let targetKeys = virtualLayout.keys(in: targetRange)
    if targetKeys != virtualWindowHandoff.targetKeys { return true }
    let visibleRange = virtualLayout.visibleRange(
      distanceFromBottom: currentDistanceFromBottom(),
      viewportHeight: contentView.bounds.height,
      overscanCount: 0
    )
    return visibleRange.contains { index in
      guard virtualLayout.keys.indices.contains(index) else { return false }
      return mountedHosts[virtualLayout.keys[index]] == nil
    }
  }

  func invalidateMeasurementForRendererTransition(_ key: String) {
    measurements.markStale(key)
    measurementCache.removeMeasurement(for: key)
  }

  func measuredRootView(for row: TranscriptVirtualRow) -> AnyView {
    guard let rowContent else { return AnyView(EmptyView()) }
    let key = row.layoutKey
    return AnyView(
      rowContent(row)
        .environment(\.streamingTextAnimationFrameClock, streamingTextFrameClock)
        .environment(\.streamMarkdownTextLayoutWidth, effectiveRowWidth)
        .environment(
          \.transcriptPerformAnchoredDisclosureChange,
          TranscriptAnchoredDisclosureChangeAction { [weak self] change in
            self?.performAnchoredDisclosureChange(in: key, change: change) ?? change()
          }
        )
        .environment(
          \.transcriptInvalidateRowMeasurement,
          TranscriptRowMeasurementInvalidationAction { [weak self] in
            self?.mountedHosts[key]?.requestContentMeasurement()
          }
        )
        .onPreferenceChange(AttachmentGeometryReadinessPreferenceKey.self) {
          [weak self] unresolvedCount in
          self?.attachmentGeometryReadinessDidChange(
            unresolvedCount == 0,
            for: key
          )
        }
        .frame(width: effectiveRowWidth, alignment: .topLeading)
        .id(key)
    )
  }

  func attachmentGeometryReadinessDidChange(_ ready: Bool, for key: String) {
    guard let host = mountedHosts[key], host.setAttachmentGeometryReady(ready) else {
      return
    }
    if !ready { pendingMeasuredHeights.removeValue(forKey: key) }
    promoteTargetWindowAndRetireIfReady()
    updateInitialPresentationReadiness()
  }

  func observeRowPresentation(_ host: TranscriptMountedRowHost, for key: String) {
    host.onHeightChange = { [weak self] height in
      self?.recordMeasuredHeight(height, for: key)
    }
    host.onPresentationReady = { [weak self] in
      self?.requestDisplayFrameOrLayout()
    }
  }

  func recordMeasuredHeight(_ rawHeight: CGFloat, for key: String) {
    let height = max(1, rawHeight.rounded(.up))
    guard rowByKey[key] != nil, mountedHosts[key]?.isAttachmentGeometryReady == true else { return }
    let needsCommit =
      pendingMeasuredHeights[key].map { abs($0 - height) > 0.5 }
      ?? measurements.needsCommit(height, for: key)
    guard needsCommit else {
      promoteTargetWindowAndRetireIfReady()
      updateInitialPresentationReadiness()
      resolveBottomJumpIfPossible()
      sendTransitions.advance()
      return
    }
    pendingMeasuredHeights[key] = height

    if presentationDisplayLink != nil, !inLiveResize {
      requestDisplayFrame()
      return
    }
    guard measurementCommitTask == nil else { return }
    measurementCommitTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard !Task.isCancelled else { return }
      self?.commitPendingMeasurements()
    }
  }

  func settleMountedRowHeights() {
    for host in mountedHosts.values {
      host.layoutSubtreeIfNeeded()
    }
    guard !pendingMeasuredHeights.isEmpty else { return }
    measurementCommitTask?.cancel()
    commitPendingMeasurements()
  }

  func commitPendingMeasurements() {
    measurementCommitTask = nil
    let pending = pendingMeasuredHeights
    pendingMeasuredHeights.removeAll(keepingCapacity: true)
    let contentShift = sendTransitions.beginContentShift()
    var committedHeights: [String: CGFloat] = [:]
    for (key, height) in pending {
      guard rowByKey[key] != nil, mountedHosts[key]?.isAttachmentGeometryReady == true,
        measurements.needsCommit(height, for: key)
      else { continue }
      if storeMeasuredHeight(height, for: key) {
        committedHeights[key] = height
      }
    }
    if !committedHeights.isEmpty {
      rebuildDocumentGeometry(changedHeights: committedHeights)
    }
    sendTransitions.commitContentShift(contentShift)
    promoteTargetWindowAndRetireIfReady()
    updateInitialPresentationReadiness()
    resolveBottomJumpIfPossible()
    sendTransitions.advance()
  }

  @discardableResult
  func storeMeasuredHeight(_ height: CGFloat, for key: String) -> Bool {
    let heightChanged = measurements.commit(height, for: key)
    if let row = rowByKey[key], row.id.isCacheableSettledRow {
      let measurement = SessionMeasuredRow(
        height: height,
        revision: row.measurementRevision
      )
      measurementCache.store(measurement, for: key)
    }
    return heightChanged
  }
}

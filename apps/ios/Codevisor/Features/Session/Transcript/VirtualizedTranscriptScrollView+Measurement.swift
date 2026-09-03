import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

// MARK: - Measurement

extension VirtualizedTranscriptScrollView {
  func invalidateChangedMeasurements(
    previousRowsByKey: [String: TranscriptVirtualRow],
    newRows: [TranscriptVirtualRow],
  ) {
    for row in newRows {
      guard row.id.isCacheableSettledRow else { continue }
      let key = row.layoutKey
      if let previous = previousRowsByKey[key] {
        guard previous.measurementRevision != row.measurementRevision else { continue }
      } else {
        // A ledger height under a key absent from the previous row set
        // came from a differently shaped row sharing the layout key
        // (the aggregate active placeholder vs. the settled shell).
        // Keep it for layout but never as this row's known height.
        guard measurements[key] != nil, !measurements.isStale(key) else { continue }
        measurements.markStale(key)
        continue
      }
      measurements.markStale(key)
      pendingMeasurements.removeValue(forKey: key)
      measurementCache.removeMeasurement(for: key)
      if let host = mountedHosts[key] {
        host.resetReportedContentHeight()
        host.requestContentMeasurement()
      }
    }
  }

  func installExactSpacerMeasurements() {
    for row in rows {
      if case let .bottomSpacer(height) = row.content {
        measurements.setExact(height, for: row.layoutKey)
      }
    }
  }

  @discardableResult
  func activateMeasurementCacheIfNeeded() -> Bool {
    guard bounds.width > 0 else { return false }
    let key = SessionMeasurementCacheKey(
      rowWidthHalfPoints: Int((effectiveRowWidth * 2).rounded()),
      layoutFingerprint: layoutFingerprint,
    )
    guard key != measurementCache.activeKey else { return false }

    measurementCommitTask?.cancel()
    measurementCommitTask = nil
    pendingMeasurements.removeAll(keepingCapacity: true)
    let cached = measurementCache.activate(key)

    let provisionalMountedHeights = Dictionary(
      uniqueKeysWithValues: mountedHosts.keys.compactMap { mountedKey in
        measurements[mountedKey].map { (mountedKey, $0) }
      },
    )
    measurements.removeAll(keepingCapacity: true)
    var valid: [String: SessionMeasuredRow] = [:]
    valid.reserveCapacity(cached.count)
    for row in rows {
      guard row.id.isCacheableSettledRow,
        let measurement = cached[row.layoutKey],
        measurement.revision == row.measurementRevision,
        measurement.height > 0
      else { continue }
      valid[row.layoutKey] = measurement
      measurements.setExact(measurement.height, for: row.layoutKey)
    }
    measurementCache.replaceActiveMeasurements(valid)
    installExactSpacerMeasurements()
    for (mountedKey, height) in provisionalMountedHeights
    where measurements[mountedKey] == nil {
      measurements.setProvisional(height, for: mountedKey)
    }

    if let restore = pendingInitialState?.virtualTranscript,
      restore.measurementCacheKey == key
    {
      for (rowKey, height) in restore.rowHeightsByKey where height > 0 {
        guard let row = rowByKey[rowKey], measurements[rowKey] == nil else { continue }
        if row.id.isCacheableSettledRow {
          guard let settled = restore.settledRowsByKey[rowKey],
            settled.revision == row.measurementRevision
          else { continue }
          measurements.setExact(height, for: rowKey)
          let measurement = SessionMeasuredRow(
            height: height,
            revision: settled.revision,
          )
          measurementCache.store(measurement, for: rowKey)
        } else {
          measurements.setProvisional(height, for: rowKey)
        }
      }
    }
    return true
  }

  func rebuildDocumentGeometry(changedHeights: [String: CGFloat]? = nil) {
    let previousLayout = virtualLayout
    let previousDistance = initialPositionApplied ? currentDistanceFromBottom() : nil
    // ChatGPT follows the bottom only while the latest turn is live. An
    // idle transcript is static even when its distance is zero, so opening
    // a disclosure preserves the reader's viewport instead of pushing the
    // clicked header offscreen.
    let plan = TranscriptGeometryRebuildPlan(
      previousLayout: previousLayout,
      previousDistanceFromBottom: previousDistance,
      viewportHeight: viewportHeight,
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

      let documentSize = CGSize(
        width: max(1, bounds.width),
        height: paginationHeaderLayout.documentHeight(
          topPadding: Self.topPadding,
          rowsHeight: virtualLayout.totalHeight
        ),
      )
      contentSize = documentSize
      canvasView.frame = CGRect(origin: .zero, size: documentSize)
      positionPaginationLoadingIndicator()
      positionMountedRows()

      if !initialPositionApplied {
        applyPendingInitialPositionIfPossible()
      } else if let anchor = disclosureViewportAnchor {
        setViewportTop(anchor.viewportTop)
      } else if let resolvedDistance = plan.resolvedDistanceFromBottom(
        newLayout: virtualLayout,
        previousLayout: previousLayout
      ) {
        if lockedRestoreDistance != nil {
          lockedRestoreDistance = resolvedDistance
        }
        setDistanceFromBottom(resolvedDistance)
      }
      lastDistanceFromBottom = currentDistanceFromBottom()
    }
    // Final geometry and its bottom compensation are now authoritative,
    // but UIKit has not committed this run-loop transaction. Lock
    // surviving rows to their captured screen coordinates here so the
    // intermediate model position can never paint.
    synchronizePendingSendHistoryPositions()
    updateMountedRows(rangeOverride: initialRestoreRange)
    updateInitialPresentationReadiness()
  }

  func measuredRootView(for row: TranscriptVirtualRow) -> AnyView {
    guard let rowContent else { return AnyView(EmptyView()) }
    let key = row.layoutKey
    return AnyView(
      rowContent(row)
        .environment(\.streamingTextAnimationFrameClock, streamingTextFrameClock)
        .environment(\.streamMarkdownTextLayoutWidth, effectiveRowWidth)
        .environment(\.transcriptPerformAnchoredDisclosureChange) { [weak self] change in
          self?.performAnchoredDisclosureChange(in: key, change: change) ?? change()
        }
        .environment(\.transcriptInvalidateRowMeasurement) { [weak self] in
          self?.mountedHosts[key]?.requestContentMeasurement()
        }
        .onPreferenceChange(AttachmentGeometryReadinessPreferenceKey.self) {
          [weak self] unresolvedCount in
          self?.attachmentGeometryReadinessDidChange(
            unresolvedCount == 0,
            for: key
          )
        }
        .frame(width: effectiveRowWidth, alignment: .topLeading)
        .id(key),
    )
  }

  func attachmentGeometryReadinessDidChange(_ ready: Bool, for key: String) {
    guard let host = mountedHosts[key], host.setAttachmentGeometryReady(ready) else {
      return
    }
    promoteTargetWindowIfReady()
    updateInitialPresentationReadiness()
  }

  func recordMeasuredHeight(_ rawMeasurement: TranscriptRowMeasurement) {
    let scale = TranscriptPixelGeometry.displayScale(for: self)
    let measurement = TranscriptRowMeasurement(
      key: rawMeasurement.key,
      revision: rawMeasurement.revision,
      rowWidthHalfPoints: rawMeasurement.rowWidthHalfPoints,
      height: max(
        1,
        TranscriptPixelGeometry.ceil(rawMeasurement.height, scale: scale),
      ),
    )
    guard accepts(measurement) else { return }
    let needsCommit =
      pendingMeasurements[measurement.key].map {
        $0.revision != measurement.revision
          || $0.rowWidthHalfPoints != measurement.rowWidthHalfPoints
          || TranscriptPixelGeometry.differs(
            $0.height,
            measurement.height,
            scale: scale,
          )
      } ?? measurements.needsCommit(measurement.height, for: measurement.key)
    guard needsCommit else {
      // Cached settled rows can report the exact height already in the
      // ledger. The host has still completed a fresh SwiftUI layout, so
      // wake presentation gates even though no geometry commit follows.
      promoteTargetWindowIfReady()
      updateInitialPresentationReadiness()
      resolveBottomJumpIfPossible()
      startPendingSendAnimationIfPossible()
      return
    }
    pendingMeasurements[measurement.key] = measurement
    guard measurementCommitGate.allowsGeometryCommit else { return }
    if presentationDisplayLink != nil {
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

  func commitPendingMeasurements() {
    measurementCommitTask?.cancel()
    measurementCommitTask = nil
    // Mounted hosts remain clipped to the currently committed ledger
    // while UIKit owns post-lift momentum. This keeps rows non-overlapping
    // without replacing the deceleration animation via contentOffset.
    guard measurementCommitGate.allowsGeometryCommit else { return }
    let pending = pendingMeasurements
    pendingMeasurements.removeAll(keepingCapacity: true)
    var committedHeights: [String: CGFloat] = [:]
    for (key, measurement) in pending {
      guard accepts(measurement),
        measurements.needsCommit(measurement.height, for: key)
      else { continue }
      if storeMeasuredHeight(measurement.height, for: key) {
        committedHeights[key] = measurement.height
      }
    }
    if !committedHeights.isEmpty {
      rebuildDocumentGeometry(changedHeights: committedHeights)
    }
    promoteTargetWindowIfReady()
    updateInitialPresentationReadiness()
    resolveBottomJumpIfPossible()
    startPendingSendAnimationIfPossible()
  }

  func accepts(_ measurement: TranscriptRowMeasurement) -> Bool {
    guard let row = rowByKey[measurement.key],
      row.measurementRevision == measurement.revision,
      measurement.rowWidthHalfPoints
        == Int((effectiveRowWidth * 2).rounded())
    else { return false }
    return true
  }

  @discardableResult
  func storeMeasuredHeight(_ height: CGFloat, for key: String) -> Bool {
    let heightChanged = measurements.commit(height, for: key)
    if let row = rowByKey[key], row.id.isCacheableSettledRow {
      let measurement = SessionMeasuredRow(
        height: height,
        revision: row.measurementRevision,
      )
      measurementCache.store(measurement, for: key)
    }
    return heightChanged
  }
}

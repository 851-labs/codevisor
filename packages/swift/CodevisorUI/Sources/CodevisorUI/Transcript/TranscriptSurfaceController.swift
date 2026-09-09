import CodevisorCore
import CoreGraphics
import Foundation
import StreamMarkdown
import TranscriptKit

/// Native side effects of committing a document change. The controller owns
/// the order; adapters own host types, measurement execution, and native UI.
@MainActor
public protocol TranscriptSurfaceAdapter: AnyObject {
  func invalidateChangedMeasurements(
    previousRowsByKey: [String: TranscriptVirtualRow], newRows: [TranscriptVirtualRow]
  )
  func reconcileRetainedHosts(
    previousRowsByKey: [String: TranscriptVirtualRow], layoutChanged: Bool
  )
  func reconcileChangedActiveHosts(previousRows: [TranscriptVirtualRow])
  @discardableResult func activateMeasurementCacheIfNeeded() -> Bool
  func refreshMountedRootViews()
  func refreshChangedMountedRootViews(previousRowsByKey: [String: TranscriptVirtualRow])
  func rebuildDocumentGeometry(changedHeights: [String: CGFloat]?)
}

@MainActor
public protocol TranscriptFrameAdapter: AnyObject {
  func prepareFrameBudget()
  func presentPendingModel()
  func updateMountedRows(rangeOverride: Range<Int>?)
  var hasPendingMeasurements: Bool { get }
  var allowsMeasurementCommit: Bool { get }
  func commitPendingMeasurements()
  func finishPresentationFrame()
}

/// One owner per viewport for document state and presentation ordering. A
/// document may appear in multiple surfaces, each with independent geometry,
/// native interaction, and reveal lifetime.
@MainActor
public final class TranscriptSurfaceController {
  public var rowSet = TranscriptRowSet()
  public var virtualLayout = VirtualTranscriptLayout(items: [], measuredHeights: [:], spacing: 20)
  public var measurements = TranscriptMeasurementLedger()
  public var measurementCache = SessionMeasurementCacheStore()
  public var layoutFingerprint = 0
  public var virtualWindowHandoff = TranscriptVirtualWindowHandoff()
  public var pendingWindowScrollDelta: CGFloat = 0
  public var initialPresentationGate = TranscriptInitialPresentationGate()
  public var initialBottomPin = TranscriptInitialBottomPin()
  public var bottomJumpGate = TranscriptBottomJumpGate()
  public var lockedRestoreDistance: CGFloat?
  public var initialPositionConfigured = false
  public var initialPositionApplied = false
  public var followsLatest = true
  public var displayFrameRequested = false
  public var modelPresentationFrameRequested = false
  public var mountedRowsUpdateRequested = false
  public let streamingTextFrameClock = StreamingTextAnimationFrameClock()

  public init() {}

  public func recordPerformanceTrace(
    _ name: String, since start: UInt64, hostCount: Int, distance: @autoclosure () -> CGFloat
  ) {
    TranscriptPerformanceTrace.record(
      name, since: start,
      values: [
        "rows": Double(rowSet.rows.count), "hosts": Double(hostCount),
        "height": Double(virtualLayout.totalHeight), "distance": Double(distance()),
        "follow": followsLatest ? 1 : 0, "ready": initialPresentationGate.isReady ? 1 : 0,
      ])
  }

  /// Navigation restores the position the reader actually left. Follow intent
  /// still governs measurements during a presentation; it must not override a
  /// saved non-bottom anchor when starting a new presentation.
  @discardableResult
  public func configureInitialPosition(_ state: SessionScrollState?, followsLatest defaultFollow: Bool) -> Bool {
    guard !initialPositionConfigured else { return false }
    initialPositionConfigured = true
    initialBottomPin.configure(restoresNonBottomPosition: state.map { !$0.isAtBottom } ?? false)
    followsLatest = state?.isAtBottom ?? defaultFollow
    lockedRestoreDistance = state.flatMap { $0.isAtBottom ? nil : $0.distanceFromBottom }
    if let state {
      measurementCache.restore(caches: state.measurementCaches, lru: state.measurementCacheLRU)
    }
    return true
  }

  /// Arrival eligibility is independent of the native host implementation.
  /// Observe before mounting so cached and uncached surfaces consume the same
  /// authoritative navigation baseline.
  public func observeStreamingPresentation(_ input: TranscriptSurfaceInput) {
    let followsAnimationEdge = followsLatest || input.scrollCommand != currentScrollCommand
    input.textAnimationRegistry.observeProjectedStreams(
      input.activeRows.compactMap { row in
        guard case let .markdownChunk(chunk) = row.content,
          chunk.lifecycle == .receiving
        else { return nil }
        return chunk.animationStreamID
      },
      animatesNewStreams: input.presentationRole == .foreground
        && input.allowsLiveTextAnimation && followsAnimationEdge,
      initialProjectionIsPending: input.isLoadingInitialHistory || input.isActiveProjectionPending,
      restorationID: input.activeTextRestorationID,
      projectionRevision: input.activeRowsVersion.sourceRevision
    )
  }

  public var currentScrollCommand = TranscriptScrollCommand()

  @discardableResult
  public func applyRows(
    _ rows: [TranscriptVirtualRow], layoutChanged: Bool, adapter: any TranscriptSurfaceAdapter
  ) -> Bool {
    let geometryChanged = layoutChanged || rowSet.geometryChanged(comparedTo: rows)
    if geometryChanged {
      if !layoutChanged {
        TranscriptRowSet.preserveWaitingActivityHeight(from: rowSet.rows, to: rows, ledger: &measurements)
      }
      TranscriptRowSet.transferActiveHeightIfNeeded(from: rowSet.rows, to: rows, ledger: &measurements)
      adapter.invalidateChangedMeasurements(previousRowsByKey: rowSet.rowByKey, newRows: rows)
    }
    let previous = rowSet.replaceRows(rows)
    adapter.reconcileRetainedHosts(previousRowsByKey: previous, layoutChanged: layoutChanged)
    if geometryChanged {
      adapter.activateMeasurementCacheIfNeeded()
      installExactSpacerMeasurements()
    }
    if layoutChanged {
      adapter.refreshMountedRootViews()
    } else {
      adapter.refreshChangedMountedRootViews(previousRowsByKey: previous)
    }
    if geometryChanged { adapter.rebuildDocumentGeometry(changedHeights: nil) }
    return geometryChanged
  }

  @discardableResult
  public func applyActiveRows(
    _ rows: [TranscriptVirtualRow], adapter: any TranscriptSurfaceAdapter
  ) -> Bool {
    switch rowSet.replaceActiveRows(rows) {
    case let .rebuild(resolved):
      return applyRows(resolved, layoutChanged: false, adapter: adapter)
    case let .inPlace(_, previous):
      adapter.reconcileChangedActiveHosts(previousRows: previous)
      adapter.refreshChangedMountedRootViews(
        previousRowsByKey: Dictionary(uniqueKeysWithValues: previous.map { ($0.layoutKey, $0) })
      )
      return false
    }
  }

  public func installExactSpacerMeasurements() {
    for row in rowSet.rows {
      if case let .bottomSpacer(height) = row.content {
        measurements.setExact(height, for: row.layoutKey)
      }
    }
  }

  /// Frame requests raised by native layout callbacks survive for the next
  /// frame. Both platforms commit model, mounting, geometry, and reveal in
  /// this order; native momentum determines whether geometry may commit.
  public func presentFrame(at timestamp: TimeInterval, adapter: any TranscriptFrameAdapter) {
    let traceStart = TranscriptPerformanceTrace.begin()
    defer {
      TranscriptPerformanceTrace.record(
        "frame", since: traceStart,
        values: [
          "timestamp": timestamp, "rows": Double(rowSet.rows.count),
          "activeFades": Double(streamingTextFrameClock.activeClientCount),
          "requestedNext": displayFrameRequested ? 1 : 0,
        ])
    }

    let presentModel = modelPresentationFrameRequested
    let updateMounts = mountedRowsUpdateRequested
    displayFrameRequested = false
    modelPresentationFrameRequested = false
    mountedRowsUpdateRequested = false
    adapter.prepareFrameBudget()
    if presentModel { adapter.presentPendingModel() }
    if updateMounts { adapter.updateMountedRows(rangeOverride: nil) }
    if adapter.hasPendingMeasurements, adapter.allowsMeasurementCommit {
      adapter.commitPendingMeasurements()
    }
    streamingTextFrameClock.tick(at: timestamp)
    adapter.finishPresentationFrame()
  }
}

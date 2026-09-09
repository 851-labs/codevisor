import CoreGraphics
import CodevisorCore
import Foundation
import Testing
import TranscriptKit
@testable import CodevisorUI

@MainActor
struct TranscriptSurfaceControllerTests {
  @Test(arguments: [false, true], [false, true])
  func navigationRestoresActualPosition(savedAtBottom: Bool, savedFollowIntent: Bool) {
    let controller = TranscriptSurfaceController()
    let state = SessionScrollState(
      distanceFromBottom: savedAtBottom ? 0 : 640,
      measurementCaches: [:],
      measurementCacheLRU: [],
      followMode: savedFollowIntent ? .followingLatest : .staticPosition
    )
    #expect(controller.configureInitialPosition(state, followsLatest: !savedAtBottom))
    #expect(controller.followsLatest == savedAtBottom)
    #expect(controller.lockedRestoreDistance == (savedAtBottom ? nil : 640))
    #expect(!controller.configureInitialPosition(nil, followsLatest: !savedAtBottom))
    #expect(controller.followsLatest == savedAtBottom)
  }

  private final class Adapter: TranscriptSurfaceAdapter, TranscriptFrameAdapter {
    var events: [String] = []
    var hasPendingMeasurements = true
    var allowsMeasurementCommit = true
    var onMount: (() -> Void)?
    func prepareFrameBudget() { events.append("budget") }
    func presentPendingModel() { events.append("model") }
    func updateMountedRows(rangeOverride: Range<Int>?) {
      events.append("mount")
      onMount?()
    }
    func commitPendingMeasurements() {
      events.append("measure")
      hasPendingMeasurements = false
    }
    func finishPresentationFrame() { events.append("finish") }
    func invalidateChangedMeasurements(
      previousRowsByKey: [String: TranscriptVirtualRow], newRows: [TranscriptVirtualRow]
    ) { events.append("invalidate") }
    func reconcileRetainedHosts(
      previousRowsByKey: [String: TranscriptVirtualRow], layoutChanged: Bool
    ) { events.append("retain") }
    func reconcileChangedActiveHosts(previousRows: [TranscriptVirtualRow]) { events.append("active") }
    func activateMeasurementCacheIfNeeded() -> Bool {
      events.append("cache")
      return true
    }
    func refreshMountedRootViews() { events.append("refresh-all") }
    func refreshChangedMountedRootViews(previousRowsByKey: [String: TranscriptVirtualRow]) {
      events.append("refresh-changed")
    }
    func rebuildDocumentGeometry(changedHeights: [String: CGFloat]?) { events.append("geometry") }
  }

  @Test func frameCommitsInOrderAndRetainsRequestsRaisedDuringLayout() {
    let controller = TranscriptSurfaceController()
    let adapter = Adapter()
    controller.modelPresentationFrameRequested = true
    controller.mountedRowsUpdateRequested = true
    adapter.onMount = {
      controller.displayFrameRequested = true
      controller.mountedRowsUpdateRequested = true
    }
    controller.presentFrame(at: 10, adapter: adapter)
    #expect(adapter.events == ["budget", "model", "mount", "measure", "finish"])
    #expect(controller.displayFrameRequested)
    #expect(controller.mountedRowsUpdateRequested)
    #expect(!controller.modelPresentationFrameRequested)

    adapter.events = []
    adapter.onMount = nil
    controller.presentFrame(at: 11, adapter: adapter)
    #expect(adapter.events == ["budget", "mount", "finish"])
    #expect(!controller.displayFrameRequested)
  }

  @Test func momentumDefersGeometryWithoutDeferringOtherFrameWork() {
    let controller = TranscriptSurfaceController()
    let adapter = Adapter()
    adapter.allowsMeasurementCommit = false
    controller.mountedRowsUpdateRequested = true
    controller.presentFrame(at: 10, adapter: adapter)
    #expect(adapter.events == ["budget", "mount", "finish"])
    #expect(adapter.hasPendingMeasurements)
    adapter.events = []
    adapter.allowsMeasurementCommit = true
    controller.presentFrame(at: 11, adapter: adapter)
    #expect(adapter.events == ["budget", "measure", "finish"])
  }

  @Test func contentOnlyChangeDoesNotRebuildGeometry() {
    let controller = TranscriptSurfaceController()
    let adapter = Adapter()
    let id = UUID()
    let first = TranscriptVirtualRow(id: .message(id), content: .error("first"), estimatedHeight: 40)
    #expect(controller.applyRows([first], layoutChanged: false, adapter: adapter))
    #expect(adapter.events == ["invalidate", "retain", "cache", "refresh-changed", "geometry"])
    adapter.events = []
    let changed = TranscriptVirtualRow(id: .message(id), content: .error("next"), estimatedHeight: 40)
    #expect(!controller.applyRows([changed], layoutChanged: false, adapter: adapter))
    #expect(adapter.events == ["retain", "refresh-changed"])
    #expect(controller.rowSet.rowByKey[first.layoutKey]?.content == .error("next"))
  }
}

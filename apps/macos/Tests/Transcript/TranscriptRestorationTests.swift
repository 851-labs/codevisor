import AppKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import Testing
import TranscriptKit
@testable import TranscriptSurface

@Suite("Native transcript restoration", .serialized)
@MainActor
struct TranscriptRestorationTests {
  private func row(height: CGFloat = 200) -> TranscriptVirtualRow {
    .init(id: .message(UUID()), content: .error("fixture"), estimatedHeight: height)
  }

  private func controller() -> SessionController {
    SessionController(
      project: .fromFolder(URL(fileURLWithPath: "/tmp/transcript-restoration-tests")),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
  }

  private func configure(
    _ view: VirtualizedTranscriptScrollView,
    controller: SessionController,
    rows: [TranscriptVirtualRow],
    token: Int = 0,
    revision: UInt64 = 0,
    preparing: Bool = false
  ) {
    let visibility = TranscriptWorkedRowsVisibilityCache().presentSettled(
      rows, sourceVersion: revision, disclosure: controller.disclosure,
      runningSubagentToolCallIDs: []
    ).visibilityRevision
    view.configure(
      TranscriptSurfaceInput(
        sessionController: controller, rows: rows, activeRows: [],
        activeRowsVersion: .init(sourceRevision: 0, visibilityRevision: visibility),
        rowsVersion: .init(sourceRevision: revision, visibilityRevision: visibility),
        projectionRevision: revision, initialState: controller.scrollState,
        followsLatest: controller.scrollState?.followMode.followsLatest ?? true,
        hasOlderHistory: false, showsOlderHistoryLoadingIndicator: false,
        isLoadingInitialHistory: false, isPreparingInitialProjection: preparing,
        isActiveProjectionPending: false, layoutFingerprint: 0,
        scrollCommand: .init(token: token), sendAnimationRequest: nil,
        textAnimationRegistry: StreamingTextAnimationRegistry(), reduceMotion: true
      ),
      callbacks: TranscriptSurfaceCallbacks(
        claimSendAnimation: { _ in false },
        rowContent: { AnyView(Color.clear.frame(height: $0.estimatedHeight)) },
        onViewportChange: { controller.scrollState = $0 },
        onBottomStateChange: { _ in }, onFollowStateChange: { _ in }, onNearTop: { false }
      )
    )
    for _ in 0..<10 {
      view.layout()
      for host in view.mountedHosts.values { host.prepareForImmediatePresentation() }
      view.commitPendingMeasurements()
      if view.initialPresentationGate.isReady && view.pendingMeasuredHeights.isEmpty { break }
    }
    if !preparing { #expect(view.initialPresentationGate.isReady) }
  }

  private func makeView() -> VirtualizedTranscriptScrollView {
    _ = NSApplication.shared
    return VirtualizedTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
  }

  private func scrollUp(_ view: VirtualizedTranscriptScrollView) {
    view.isHandlingUserInput = true
    view.contentView.scroll(to: CGPoint(x: 0, y: view.contentView.bounds.minY - 173))
    view.viewportDidScroll()
    view.isHandlingUserInput = false
    view.persistViewport()
  }

  @Test("Layout before a delayed wheel notification must not erase scroll intent")
  func delayedScrollNotification() {
    let controller = controller()
    let rows = (0..<8).map { _ in row() }
    let view = makeView()
    defer { view.prepareForDismantle() }
    configure(view, controller: controller, rows: rows)
    view.contentView.postsBoundsChangedNotifications = false
    view.isHandlingUserInput = true
    view.markRecentUserInput()
    view.contentView.scroll(to: CGPoint(x: 0, y: view.contentView.bounds.minY - 173))
    view.layout()
    view.isHandlingUserInput = false
    view.contentView.postsBoundsChangedNotifications = true
    view.viewportDidScroll()
    #expect(!view.followsLatest)
    view.persistViewport()
    #expect(controller.scrollState?.followMode == .staticPosition)
  }

  @Test("Recreating a chat after sending does not replay its old bottom command")
  func warmRestoreAfterSend() {
    let controller = controller()
    let rows = (0..<8).map { _ in row() }
    let view = makeView()
    defer { view.prepareForDismantle() }
    configure(view, controller: controller, rows: rows)
    configure(view, controller: controller, rows: rows, token: 1)
    scrollUp(view)
    let anchor = view.currentViewportAnchor()
    let top = view.contentView.bounds.minY
    view.prepareForDismantle()
    view.prepareForPresentationAttachment()
    view.isDetaching = false
    // ChatScreen creates a fresh @State command counter, starting at zero.
    configure(view, controller: controller, rows: rows)
    #expect(view.contentView.bounds.minY == top)
    #expect(view.currentViewportAnchor() == anchor)
    #expect(!view.followsLatest)
  }

  @Test("Reattaching restores the saved row after AppKit resets detached geometry")
  func warmRestoreAfterGeometryReset() {
    let controller = controller()
    let rows = (0..<8).map { _ in row() }
    let view = makeView()
    defer { view.prepareForDismantle() }
    configure(view, controller: controller, rows: rows)
    scrollUp(view)
    let anchor = view.currentViewportAnchor()
    let top = view.contentView.bounds.minY
    view.prepareForDismantle()
    view.contentView.scroll(to: .zero)
    view.prepareForPresentationAttachment()
    view.isDetaching = false
    configure(view, controller: controller, rows: rows)
    #expect(view.contentView.bounds.minY == top)
    #expect(view.currentViewportAnchor() == anchor)
  }

  @Test("A fresh jump while the reopened projection loads still follows the bottom")
  func newCommandWhileReopening() {
    let controller = controller()
    let rows = (0..<8).map { _ in row() }
    let view = makeView()
    defer { view.prepareForDismantle() }
    configure(view, controller: controller, rows: rows, token: 3)
    scrollUp(view)
    view.prepareForDismantle()
    view.prepareForPresentationAttachment()
    view.isDetaching = false
    configure(view, controller: controller, rows: rows, preparing: true)
    configure(view, controller: controller, rows: rows, token: 1, preparing: true)
    configure(view, controller: controller, rows: rows + [row()], token: 1, revision: 1)
    #expect(view.currentDistanceFromBottom() <= 0.5)
    #expect(view.followsLatest)
  }

  @Test("Leaving again before the projection is ready cannot overwrite the saved anchor")
  func leaveDuringPendingRestore() {
    let controller = controller()
    let rows = (0..<8).map { _ in row() }
    let view = makeView()
    defer { view.prepareForDismantle() }
    configure(view, controller: controller, rows: rows)
    scrollUp(view)
    let anchor = view.currentViewportAnchor()
    view.prepareForDismantle()
    view.contentView.scroll(to: .zero)
    view.prepareForPresentationAttachment()
    view.isDetaching = false
    configure(view, controller: controller, rows: rows, preparing: true)
    view.prepareForDismantle()
    #expect(controller.scrollState?.virtualTranscript?.viewportAnchor == anchor)
    view.prepareForPresentationAttachment()
    view.isDetaching = false
    configure(view, controller: controller, rows: rows)
    #expect(view.currentViewportAnchor() == anchor)
  }

  @Test("A reader away from the bottom restores the exact row despite new messages", arguments: [false, true])
  func restoreWithNewMessages(cold: Bool) {
    let controller = controller()
    let rows = (0..<8).map { _ in row() }
    let original = makeView()
    configure(original, controller: controller, rows: rows)
    scrollUp(original)
    let anchor = original.currentViewportAnchor()
    let top = original.contentView.bounds.minY
    original.prepareForDismantle()
    let reopened = cold ? makeView() : original
    defer { reopened.prepareForDismantle() }
    reopened.prepareForPresentationAttachment()
    reopened.isDetaching = false
    let added = row(height: 350)
    configure(reopened, controller: controller, rows: rows + [added], revision: 1)
    reopened.recordMeasuredHeight(470, for: added.layoutKey)
    reopened.commitPendingMeasurements()
    #expect(reopened.contentView.bounds.minY == top)
    #expect(reopened.currentViewportAnchor() == anchor)
  }

  @Test("Leaving at the bottom reopens at the newest bottom", arguments: [false, true], [false, true])
  func bottomRestoreWithNewMessages(cold: Bool, previouslyFollowing: Bool) {
    let controller = controller()
    let rows = (0..<8).map { _ in row() }
    let original = makeView()
    configure(original, controller: controller, rows: rows)
    original.followsLatest = previouslyFollowing
    original.prepareForDismantle()
    let reopened = cold ? makeView() : original
    defer { reopened.prepareForDismantle() }
    reopened.prepareForPresentationAttachment()
    reopened.isDetaching = false
    let added = row(height: 350)
    configure(reopened, controller: controller, rows: rows + [added], revision: 1)
    reopened.recordMeasuredHeight(470, for: added.layoutKey)
    reopened.commitPendingMeasurements()
    #expect(reopened.currentDistanceFromBottom() <= 0.5)
    #expect(reopened.followsLatest)
  }

  @Test("Leaving an expanded disclosure restores its position without following new messages")
  func nonBottomRestoreWithFollowingFlag() {
    let controller = controller()
    let rows = (0..<8).map { _ in row() }
    let original = makeView()
    configure(original, controller: controller, rows: rows)
    original.setDistanceFromBottom(173)
    let top = original.contentView.bounds.minY
    original.prepareForDismantle()
    let reopened = makeView()
    defer { reopened.prepareForDismantle() }
    let added = row(height: 350)
    configure(reopened, controller: controller, rows: rows + [added], revision: 1)
    reopened.recordMeasuredHeight(470, for: added.layoutKey)
    reopened.commitPendingMeasurements()
    #expect(reopened.contentView.bounds.minY == top)
    #expect(!reopened.followsLatest)
  }
}

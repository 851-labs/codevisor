import AppKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import Testing
import TranscriptKit
@testable import TranscriptSurface

@Suite("Transcript bottom clearance", .serialized)
@MainActor
struct TranscriptBottomClearanceTests {
  private let controller = SessionController(
    project: .fromFolder(URL(fileURLWithPath: "/tmp/transcript-bottom-clearance-tests")),
    configCache: ConfigOptionCache(store: InMemoryStore())
  )
  private let rows = (0..<8).map { _ in
    TranscriptVirtualRow(id: .message(UUID()), content: .error("fixture"), estimatedHeight: 200)
  }

  @Test("The page's clearance sets the space below the last row without a new projection")
  func clearanceChangeAloneMovesTheBottomSpace() {
    let view = makeView()
    defer { view.prepareForDismantle() }

    configure(view, clearance: 150)
    #expect(spacerHeight(in: view) == 150)

    configure(view, clearance: 120)
    #expect(spacerHeight(in: view) == 120)
    #expect(view.projectedRows == rows)
  }

  @Test("A page that has not measured its composer keeps the transcript's current clearance")
  func unmeasuredClearanceKeepsTheCurrentSpace() {
    let view = makeView()
    defer { view.prepareForDismantle() }

    configure(view, clearance: 150)
    configure(view, clearance: nil)
    #expect(spacerHeight(in: view) == 150)
  }

  @Test("A chat whose transcript follows the latest row stays at the bottom when the clearance grows")
  func followingTranscriptStaysAtTheBottom() {
    let view = makeView()
    defer { view.prepareForDismantle() }

    configure(view, clearance: 120)
    configure(view, clearance: 200)
    #expect(view.currentDistanceFromBottom() <= 1)
  }

  private func spacerHeight(in view: VirtualizedTranscriptScrollView) -> CGFloat? {
    guard case let .bottomSpacer(height)? = view.rows.last?.content else { return nil }

    return height
  }

  private func makeView() -> VirtualizedTranscriptScrollView {
    _ = NSApplication.shared
    return VirtualizedTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
  }

  private func configure(_ view: VirtualizedTranscriptScrollView, clearance: CGFloat?) {
    view.configure(input(clearance: clearance), callbacks: callbacks)
    for _ in 0..<10 {
      view.layout()
      for host in view.mountedHosts.values { host.prepareForImmediatePresentation() }
      view.commitPendingMeasurements()
      if view.initialPresentationGate.isReady && view.pendingMeasuredHeights.isEmpty { break }
    }
  }

  private func input(clearance: CGFloat?) -> TranscriptSurfaceInput {
    let visibility = TranscriptWorkedRowsVisibilityCache().presentSettled(
      rows, sourceVersion: 1, disclosure: controller.disclosure
    ).visibilityRevision
    return TranscriptSurfaceInput(
      sessionController: controller, rows: rows, activeRows: [],
      activeRowsVersion: .init(sourceRevision: 0, visibilityRevision: visibility),
      rowsVersion: .init(sourceRevision: 1, visibilityRevision: visibility),
      projectionRevision: 1, initialState: nil, followsLatest: true,
      hasOlderHistory: false, showsOlderHistoryLoadingIndicator: false,
      isLoadingInitialHistory: false, isPreparingInitialProjection: false,
      isActiveProjectionPending: false, layoutFingerprint: 0,
      scrollCommand: .init(), sendAnimationRequest: nil,
      textAnimationRegistry: StreamingTextAnimationRegistry(), reduceMotion: true,
      bottomContentClearance: clearance
    )
  }

  private var callbacks: TranscriptSurfaceCallbacks {
    TranscriptSurfaceCallbacks(
      claimSendAnimation: { _ in false },
      rowContent: { AnyView(Color.clear.frame(height: $0.estimatedHeight)) },
      onViewportChange: { _ in },
      onBottomStateChange: { _ in }, onFollowStateChange: { _ in }, onNearTop: { false }
    )
  }
}

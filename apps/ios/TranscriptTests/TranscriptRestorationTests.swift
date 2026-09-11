import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import Testing
import TranscriptKit
import UIKit

@testable import TranscriptSurface

@Suite("iOS transcript restoration")
@MainActor
struct TranscriptRestorationTests {
  @Test("Reopening before the first measurement commit reveals the retained transcript", arguments: [false, true])
  func reopeningBeforeFirstPaint(wasDecelerating: Bool) async throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
    let parent = UIViewController()
    window.rootViewController = parent
    window.isHidden = false
    let view = VirtualizedTranscriptScrollView(frame: window.bounds)
    view.hostingParent = parent
    parent.view.addSubview(view)
    defer {
      view.prepareForDismantle()
      view.removeFromSuperview()
      window.isHidden = true
      window.rootViewController = nil
    }
    let controller = SessionController(
      project: .fromFolder(URL(fileURLWithPath: "/tmp/ios-transcript-restoration")),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
    let row = TranscriptVirtualRow(
      id: .message(UUID()), content: .error("Retained message"), estimatedHeight: 80
    )
    view.measurementCommitGate.draggingDidEnd(willDecelerate: wasDecelerating)
    configure(view, controller: controller, rows: [row])
    view.layoutIfNeeded()
    let host = try #require(view.mountedHosts[row.layoutKey])
    await withCheckedContinuation { continuation in
      let forward = host.onMeasuredHeight
      host.onMeasuredHeight = { measurement in
        forward?(measurement)
        host.onMeasuredHeight = forward
        #expect(view.pendingMeasurements[row.layoutKey] != nil)
        // Navigate synchronously from the measurement callback, before
        // the display clock can commit it. Both orders are controlled.
        view.suspendPresentation()
        view.removeFromSuperview()
        continuation.resume()
      }
      host.requestContentMeasurement()
      host.prepareForImmediatePresentation()
    }
    #expect(host.isPresentationReady)
    #expect(view.measurements[row.layoutKey] == nil)
    #expect(!view.initialPresentationGate.isReady)
    #expect(view.canvasView.alpha == 0)

    // A queued callback must not consume the retained measurements while
    // there is no presentation owner. Reattachment owns the commit.
    view.commitPendingMeasurements()
    #expect(view.pendingMeasurements[row.layoutKey] != nil)
    #expect(view.measurements[row.layoutKey] == nil)

    view.prepareForPresentationAttachment()
    parent.view.addSubview(view)
    configure(view, controller: controller, rows: [row])
    view.layoutIfNeeded()
    // Drive precisely one presentation frame, without a timeout, a network
    // refresh, a new projection, or another row measurement.
    view.surfaceController.presentFrame(at: 1, adapter: view)

    #expect(view.mountedHosts[row.layoutKey] === host)
    #expect(view.measurementCommitGate.allowsGeometryCommit)
    #expect(view.measurements[row.layoutKey] != nil)
    #expect(view.initialPresentationGate.isReady)
    #expect(view.canvasView.alpha == 1)
    #expect(view.isScrollEnabled)
  }

  private func configure(
    _ view: VirtualizedTranscriptScrollView,
    controller: SessionController,
    rows: [TranscriptVirtualRow]
  ) {
    let visibility = TranscriptWorkedRowsVisibilityCache().presentSettled(
      rows, sourceVersion: 0, disclosure: controller.disclosure,
      runningSubagentToolCallIDs: []
    ).visibilityRevision
    view.configure(
      TranscriptSurfaceInput(
        sessionController: controller, rows: rows, activeRows: [],
        activeRowsVersion: .init(sourceRevision: 0, visibilityRevision: visibility),
        rowsVersion: .init(sourceRevision: 0, visibilityRevision: visibility),
        projectionRevision: 0, initialState: nil, followsLatest: true,
        hasOlderHistory: false, showsOlderHistoryLoadingIndicator: false,
        isLoadingInitialHistory: false, isPreparingInitialProjection: false,
        isActiveProjectionPending: false, layoutFingerprint: 0,
        scrollCommand: .init(), sendAnimationRequest: nil,
        textAnimationRegistry: StreamingTextAnimationRegistry(), reduceMotion: true
      ),
      callbacks: TranscriptSurfaceCallbacks(
        claimSendAnimation: { _ in false },
        rowContent: { AnyView(Text("Retained message").frame(height: $0.estimatedHeight)) },
        onViewportChange: { _ in }, onBottomStateChange: { _ in },
        onFollowStateChange: { _ in }, onNearTop: { false }
      )
    )
  }
}

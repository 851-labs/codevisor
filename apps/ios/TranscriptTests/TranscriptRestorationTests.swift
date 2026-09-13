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
  @Test(
    "First display preserves send holds and waits for the landed assistant layout",
    arguments: [UserSendAnimationDestination.optimistic, .activeTurn]
  )
  func firstDisplayDuringSend(destination: UserSendAnimationDestination) throws {
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
      project: .fromFolder(URL(fileURLWithPath: "/tmp/ios-transcript-send-readiness")),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
    let older = TranscriptVirtualRow(id: .message(UUID()), content: .error("Older message"), estimatedHeight: 1_000)
    let user = UserMessage(text: "A message that fills the visible viewport")
    let userRow = TranscriptVirtualRow(
      id: .message(user.id),
      content: destination == .optimistic
        ? .optimistic(user, showsStartingAgent: false)
        : .message(.user(user), waitingOnBackgroundTask: nil),
      estimatedHeight: 700)
    let assistantRow = try #require(
      TranscriptActiveRowProjection.rows(
        for: .assistant(AssistantMessage(turn: AssistantTurn(isGenerating: true)))
      ).first)
    let spacer = TranscriptVirtualRow(id: .bottomSpacer, content: .bottomSpacer(100), estimatedHeight: 100)
    configure(
      view, controller: controller, rows: [older, userRow, assistantRow, spacer], isLoadingInitialHistory: true)
    view.layoutIfNeeded()
    for host in view.mountedHosts.values { host.prepareForImmediatePresentation() }
    view.commitPendingMeasurements()
    view.attachmentGeometryReadinessDidChange(false, for: older.layoutKey)
    let userHost = try #require(view.mountedHosts[userRow.layoutKey])
    let assistantHost = try #require(view.mountedHosts[assistantRow.layoutKey])
    let request = UserSendAnimationRequest(token: 1, messageID: user.id, destination: destination)
    let sourceLayout = VirtualTranscriptLayout(items: [], measuredHeights: [:], spacing: 20)
    view.reduceMotion = false
    view.pendingSendAnimationRequest = request
    view.pendingSendAnimationRowKey = userRow.layoutKey
    view.pendingSendSourceLayout = sourceLayout
    view.synchronizePendingSendTargetVisibility()
    view.synchronizeSendAssistantVisibility()
    let targetFrame = userHost.frame

    // The relaxed first-display gate must not release the independent send
    // holds or move the destination, even with offscreen history unfinished.
    view.isLoadingInitialHistory = false
    view.updateInitialPresentationReadiness()
    #expect(view.initialPresentationGate.isReady)
    #expect(view.canvasView.alpha == 1)
    #expect(userHost.frame == targetFrame)
    #expect(userHost.layer.animation(forKey: TranscriptSendAnimationKeys.targetHold) != nil)
    #expect(assistantHost.layer.animation(forKey: TranscriptSendAnimationKeys.assistantHold) != nil)

    // An active-turn send waits for the whole tail; a first send may fly
    // into its optimistic bubble while the assistant is still preparing.
    assistantHost.resetReportedContentHeight()
    #expect(
      view.sendHistoryDestinationIsReady(request: request, sourceLayout: sourceLayout, rowKey: userRow.layoutKey)
        == (destination == .optimistic))
    assistantHost.prepareForImmediatePresentation()
    view.commitPendingMeasurements()
    #expect(view.sendHistoryDestinationIsReady(request: request, sourceLayout: sourceLayout, rowKey: userRow.layoutKey))

    view.pendingSendAnimationRequest = nil
    view.pendingSendAnimationRowKey = nil
    view.beginSendPresentation(request: request, sourceLayout: sourceLayout, sourceScreenYByRowKey: nil)
    var completions = 0
    view.onSendAnimationCompleted = { _ in completions += 1 }
    assistantHost.resetReportedContentHeight()
    view.finishSendPresentation(token: request.token, notifyCompletion: true)
    #expect(completions == 0)
    #expect(view.activeSendAnimationRequest == request)
    #expect(assistantHost.layer.animation(forKey: TranscriptSendAnimationKeys.assistantHold) != nil)

    // Drive the actual replacement layout and completion event; no elapsed
    // animation time or background/foreground cycle controls the outcome.
    assistantHost.prepareForImmediatePresentation()
    view.completePendingSendPresentationIfPossible()
    #expect(completions == 1)
    #expect(view.activeSendAnimationRequest == nil)
    #expect(assistantHost.layer.animation(forKey: TranscriptSendAnimationKeys.assistantHold) == nil)
    view.completePendingSendPresentationIfPossible()
    #expect(completions == 1)
  }

  @Test("Only visible content readiness blocks first display", arguments: [false, true])
  func pendingContentAtFirstDisplay(isVisible: Bool) throws {
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
      project: .fromFolder(URL(fileURLWithPath: "/tmp/ios-transcript-first-display")),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
    let older = TranscriptVirtualRow(id: .message(UUID()), content: .error("Older message"), estimatedHeight: 1_000)
    let latest = TranscriptVirtualRow(id: .message(UUID()), content: .error("Latest message"), estimatedHeight: 700)
    let spacer = TranscriptVirtualRow(id: .bottomSpacer, content: .bottomSpacer(100), estimatedHeight: 100)
    let rows = [older, latest, spacer]
    var presentationCount = 0
    view.onInitialPresentationReady = { [weak view] in
      #expect(view?.canvasView.alpha == 1)
      #expect(view?.isScrollEnabled == true)
      presentationCount += 1
    }
    configure(view, controller: controller, rows: rows, isLoadingInitialHistory: true)
    view.layoutIfNeeded()
    for host in view.mountedHosts.values { host.prepareForImmediatePresentation() }
    view.commitPendingMeasurements()
    let blocked = isVisible ? latest : older
    let host = try #require(view.mountedHosts[blocked.layoutKey])
    view.attachmentGeometryReadinessDidChange(false, for: blocked.layoutKey)
    let visibleKeys = view.virtualLayout.keys(
      in: view.virtualLayout.visibleRange(
        distanceFromBottom: view.currentDistanceFromBottom(), viewportHeight: view.viewportHeight, overscanCount: 0
      ))
    #expect(visibleKeys.contains(blocked.layoutKey) == isVisible)
    #expect(!host.isFullyPresentable)
    #expect(view.canvasView.alpha == 0)

    configure(view, controller: controller, rows: rows)
    view.layoutIfNeeded()
    view.commitPendingMeasurements()
    #expect(view.initialPresentationGate.isReady == !isVisible)
    #expect(view.canvasView.alpha == (isVisible ? 0 : 1))
    #expect(view.isScrollEnabled == !isVisible)
    #expect(presentationCount == (isVisible ? 0 : 1))

    view.attachmentGeometryReadinessDidChange(true, for: blocked.layoutKey)
    host.prepareForImmediatePresentation()
    view.commitPendingMeasurements()
    view.updateInitialPresentationReadiness()
    #expect(view.canvasView.alpha == 1)
    #expect(presentationCount == 1)
  }

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
    rows: [TranscriptVirtualRow],
    isLoadingInitialHistory: Bool = false
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
        isLoadingInitialHistory: isLoadingInitialHistory, isPreparingInitialProjection: false,
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

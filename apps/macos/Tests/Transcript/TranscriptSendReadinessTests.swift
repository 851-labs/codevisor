import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import SwiftUI
import Testing
import TranscriptKit
@testable import TranscriptSurface

@Suite("Native send readiness", .serialized)
@MainActor
struct TranscriptSendReadinessTests {
  @Test("A late unchanged height completes readiness without another model update")
  func lateUnchangedHeightCompletesReadiness() throws {
    _ = NSApplication.shared
    let host = TranscriptRowHost(frame: NSRect(x: 0, y: 0, width: 320, height: 15))
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    host.syncContentWidth()
    host.installRootView(AnyView(Color.clear.frame(height: 15)), knownHeight: 15)
    host.prepareForImmediatePresentation()
    #expect(host.isPresentationReady)

    let controller = try #require(host.subviews.first?.nextResponder as? TranscriptContentHostingController)
    var readinessNotifications = 0
    host.onPresentationReady = { readinessNotifications += 1 }
    // A placed-geometry report can arrive after the native layout callback.
    // Its height is already in the ledger, so no measurement commit or
    // model update will request an extra transcript layout.
    controller.onLaidOutHeightChange?(15)
    host.layoutSubtreeIfNeeded()

    #expect(host.isPresentationReady)
    #expect(readinessNotifications == 1)
  }

  @Test("An unchanged waiting height wakes the pending flight after host layout", arguments: [false, true])
  func unchangedHeightStartsFlight(lateHeightReport: Bool) throws {
    _ = NSApplication.shared
    let view = VirtualizedTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    defer {
      view.prepareForDismantle()
      window.contentView = nil
    }
    view.isPreparingInitialProjection = false
    view.initialPositionConfigured = true
    view.initialPositionApplied = true
    let user = UserMessage(text: "Again")
    let userRow = TranscriptVirtualRow(
      id: .message(user.id), content: .message(.user(user), waitingOnBackgroundTask: nil), estimatedHeight: 62
    )
    let activity = TranscriptActiveRowProjection.rows(
      for: .assistant(AssistantMessage(turn: AssistantTurn(isGenerating: true)))
    )[0]
    let rows = [
      TranscriptVirtualRow(id: .message(UUID()), content: .error("history"), estimatedHeight: 900),
      userRow,
      activity,
      TranscriptVirtualRow(id: .bottomSpacer, content: .bottomSpacer(100), estimatedHeight: 100),
    ]
    view.rowContent = { row in
      AnyView(Color.clear.frame(height: row.layoutKey == activity.layoutKey ? 15 : row.estimatedHeight))
    }
    view.layout()
    _ = view.rowSet.replaceRows(rows)
    _ = view.activateMeasurementCacheIfNeeded()
    for row in rows {
      view.measurements.setExact(row.layoutKey == activity.layoutKey ? 15 : row.estimatedHeight, for: row.layoutKey)
    }
    view.rebuildDocumentGeometry()
    for host in view.mountedHosts.values { host.prepareForImmediatePresentation() }
    view.commitPendingMeasurements()
    view.scrollToBottom()

    let link = view.displayLink(target: view, selector: #selector(view.presentationDisplayLinkDidFire(_:)))
    view.presentationDisplayLink = link
    let request = UserSendAnimationRequest(token: 1, messageID: user.id, destination: .activeTurn)
    view.pendingSendAnimationRequest = request
    view.pendingSendAnimationRowKey = userRow.layoutKey
    view.pendingSendSourceLayout = VirtualTranscriptLayout(items: [], measuredHeights: [:], spacing: 20)
    view.claimSendAnimation = { $0 == request }
    view.synchronizePendingSendTargetVisibility()
    view.synchronizeSendAssistantVisibility()

    let host = try #require(view.mountedHosts[activity.layoutKey] as? TranscriptRowHost)
    if !lateHeightReport {
      host.installRootView(AnyView(Color.clear.frame(height: 15)), knownHeight: nil)
    }
    view.displayFrameRequested = false
    link.isPaused = true
    // Flush only the host. A scroll-view layout or model update would mask
    // the missing wakeup that caused the hold to expire in the recording.
    if lateHeightReport {
      let controller = try #require(host.subviews.first?.nextResponder as? TranscriptContentHostingController)
      controller.onLaidOutHeightChange?(15)
      host.layoutSubtreeIfNeeded()
    } else {
      host.prepareForImmediatePresentation()
    }
    #expect(host.isPresentationReady)
    #expect(view.pendingMeasuredHeights.isEmpty)
    #expect(view.activeSendAnimationRequest == nil)
    #expect(view.displayFrameRequested)

    view.presentationDisplayLinkDidFire(link)
    #expect(view.pendingSendAnimationRequest == nil)
    #expect(view.activeSendAnimationRequest == request)
    #expect(view.mountedHosts[userRow.layoutKey]?.layer?.animation(forKey: TranscriptSendAnimationKeys.flight) != nil)
  }

  /// A mounted, measured, bottom-pinned transcript whose tail is the
  /// aggregate `.active` bridge (the precise projection has not published).
  @MainActor
  private struct ConnectedSendFixture {
    let view: VirtualizedTranscriptScrollView
    let window: NSWindow
    let user: UserMessage
    let userRow: TranscriptVirtualRow
    let activeRow: TranscriptVirtualRow
    let request: UserSendAnimationRequest

    init() {
      _ = NSApplication.shared
      view = VirtualizedTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
      window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = view
      view.isPreparingInitialProjection = false
      view.initialPositionConfigured = true
      view.initialPositionApplied = true
      // The precise active projection is still in flight; the send must
      // not wait for it.
      view.isActiveProjectionPending = true
      user = UserMessage(text: "tell me a joke")
      userRow = TranscriptVirtualRow(
        id: .message(user.id), content: .message(.user(user), waitingOnBackgroundTask: nil), estimatedHeight: 62
      )
      let assistant = AssistantMessage(turn: AssistantTurn(isGenerating: true))
      activeRow = TranscriptVirtualRow(
        id: .active(assistant.id), content: .active(.assistant(assistant)), estimatedHeight: 32
      )
      let rows = [
        TranscriptVirtualRow(id: .message(UUID()), content: .error("history"), estimatedHeight: 900),
        userRow,
        activeRow,
        TranscriptVirtualRow(id: .bottomSpacer, content: .bottomSpacer(100), estimatedHeight: 100),
      ]
      view.rowContent = { row in AnyView(Color.clear.frame(height: row.estimatedHeight)) }
      view.layout()
      _ = view.rowSet.replaceRows(rows)
      _ = view.activateMeasurementCacheIfNeeded()
      for row in rows {
        view.measurements.setExact(row.estimatedHeight, for: row.layoutKey)
      }
      view.rebuildDocumentGeometry()
      for host in view.mountedHosts.values { host.prepareForImmediatePresentation() }
      view.commitPendingMeasurements()
      view.scrollToBottom()

      request = UserSendAnimationRequest(token: 1, messageID: user.id, destination: .activeTurn)
      view.pendingSendAnimationRequest = request
      view.pendingSendAnimationRowKey = userRow.layoutKey
      view.pendingSendSourceLayout = VirtualTranscriptLayout(items: [], measuredHeights: [:], spacing: 20)
      view.pendingSendSourceViewportYByRowKey = view.sendHistoryViewportYByRowKey()
      view.claimSendAnimation = { [request] in $0 == request }
      view.synchronizePendingSendTargetVisibility()
      view.synchronizeSendAssistantVisibility()
    }

    func tearDown() {
      view.prepareForDismantle()
      window.contentView = nil
    }
  }

  @Test("A connected send flies before the precise active projection publishes")
  func connectedSendDoesNotWaitForThePreciseProjection() throws {
    let fixture = ConnectedSendFixture()
    defer { fixture.tearDown() }
    let view = fixture.view
    let target = try #require(view.mountedHosts[fixture.userRow.layoutKey])
    #expect(target.layer?.animation(forKey: TranscriptSendAnimationKeys.targetHold) != nil)
    #expect(view.isActiveProjectionPending)

    view.startPendingSendAnimationIfPossible()

    #expect(view.pendingSendAnimationRequest == nil)
    #expect(view.activeSendAnimationRequest == fixture.request)
    #expect(target.layer?.animation(forKey: TranscriptSendAnimationKeys.flight) != nil)
    #expect(target.layer?.animation(forKey: TranscriptSendAnimationKeys.targetHold) == nil)
    // The aggregate active row stays hidden until the bubble lands.
    let active = try #require(view.mountedHosts[fixture.activeRow.layoutKey])
    #expect(active.layer?.animation(forKey: TranscriptSendAnimationKeys.assistantHold) != nil)
  }

  @Test("The pending deadline flies into the laid-out bubble when its tail is still unmeasured")
  func pendingDeadlineForcesTheFlight() throws {
    let fixture = ConnectedSendFixture()
    defer { fixture.tearDown() }
    let view = fixture.view
    view.measurements.markStale(fixture.activeRow.layoutKey)

    view.startPendingSendAnimationIfPossible()
    #expect(view.pendingSendAnimationRequest == fixture.request)
    #expect(view.activeSendAnimationRequest == nil)
    let target = try #require(view.mountedHosts[fixture.userRow.layoutKey])
    #expect(target.layer?.animation(forKey: TranscriptSendAnimationKeys.targetHold) != nil)

    view.resolvePendingSendDeadline(token: fixture.request.token)

    #expect(view.pendingSendAnimationRequest == nil)
    #expect(view.activeSendAnimationRequest == fixture.request)
    #expect(target.layer?.animation(forKey: TranscriptSendAnimationKeys.flight) != nil)
  }

  @Test("The pending deadline reveals the held rows when the bubble never laid out")
  func pendingDeadlineRevealsWithoutADestination() throws {
    let fixture = ConnectedSendFixture()
    defer { fixture.tearDown() }
    let view = fixture.view
    view.pendingSendAnimationRowKey = nil
    let target = try #require(view.mountedHosts[fixture.userRow.layoutKey])
    #expect(target.layer?.animation(forKey: TranscriptSendAnimationKeys.targetHold) != nil)

    view.resolvePendingSendDeadline(token: fixture.request.token)

    #expect(view.pendingSendAnimationRequest == nil)
    #expect(view.activeSendAnimationRequest == nil)
    for host in view.mountedHosts.values {
      for key in TranscriptSendAnimationKeys.all {
        #expect(host.layer?.animation(forKey: key) == nil)
      }
    }
  }

  @Test("The destination hold is applied once per host and never re-applied after removal")
  func targetHoldIsPerHost() throws {
    let fixture = ConnectedSendFixture()
    defer { fixture.tearDown() }
    let view = fixture.view
    let target = try #require(view.mountedHosts[fixture.userRow.layoutKey])
    let layer = try #require(target.layer)
    #expect(layer.animation(forKey: TranscriptSendAnimationKeys.targetHold) != nil)

    // A later mount pass must not re-hide a row whose hold this host
    // already received, even if the animation has been removed.
    layer.removeAnimation(forKey: TranscriptSendAnimationKeys.targetHold)
    view.synchronizePendingSendTargetVisibility()
    #expect(layer.animation(forKey: TranscriptSendAnimationKeys.targetHold) == nil)

    // A new send resets the per-host record.
    view.sendTargetHoldMount = nil
    view.synchronizePendingSendTargetVisibility()
    #expect(layer.animation(forKey: TranscriptSendAnimationKeys.targetHold) != nil)
  }

  @Test("Held rows are not retired by model geometry while a send presentation is running")
  func heldRowsAreRetainedDuringTheSendPresentation() {
    let fixture = ConnectedSendFixture()
    defer { fixture.tearDown() }
    let view = fixture.view
    let mounted = Set(view.mountedHosts.keys)
    #expect(!mounted.isEmpty)

    view.retireMountedHosts(excluding: [])
    #expect(Set(view.mountedHosts.keys) == mounted)

    view.startPendingSendAnimationIfPossible()
    #expect(view.activeSendAnimationRequest == fixture.request)
    view.retireMountedHosts(excluding: [])
    #expect(Set(view.mountedHosts.keys) == mounted)

    view.interruptSendPresentation()
    #expect(!view.isSendPresentationHoldingHosts)
    view.retireMountedHosts(excluding: [])
    #expect(view.mountedHosts.isEmpty)
  }

  @Test("Heights below the flying bubble commit at completion, not mid-flight")
  func tailHeightsCommitAtCompletion() {
    let fixture = ConnectedSendFixture()
    defer { fixture.tearDown() }
    let view = fixture.view
    view.startPendingSendAnimationIfPossible()
    #expect(view.activeSendAnimationRequest == fixture.request)
    let activeKey = fixture.activeRow.layoutKey
    let before = view.measurements[activeKey]
    view.pendingMeasuredHeights[activeKey] = 56

    view.commitPendingMeasurements()
    #expect(view.pendingMeasuredHeights[activeKey] == 56)
    #expect(view.measurements[activeKey] == before)

    view.isApplyingSendCompletion = true
    view.commitPendingMeasurements()
    view.isApplyingSendCompletion = false
    #expect(view.pendingMeasuredHeights[activeKey] == nil)
    #expect(view.measurements[activeKey] == 56)
  }
}

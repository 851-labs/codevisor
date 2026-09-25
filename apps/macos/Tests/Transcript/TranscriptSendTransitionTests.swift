import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import SwiftUI
import Testing
import TranscriptKit
@testable import TranscriptSurface

@Suite("Native send transitions", .serialized)
@MainActor
struct TranscriptSendTransitionTests {
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

  @Test("An optimistic row animates at once, before the harness settles the message")
  func optimisticRowAnimatesImmediately() throws {
    let fixture = SendFixture()
    defer { fixture.tearDown() }

    fixture.view.sendTransitions.receive(fixture.request, isForeground: true)

    let target = try #require(fixture.view.mountedHosts[fixture.userRow.layoutKey]?.layer)
    #expect(target.animation(forKey: TranscriptSendAnimationKeys.lift) != nil)
    #expect(fixture.events.started == [fixture.request.token])
    #expect(fixture.events.claimed == [fixture.request.token])
    #expect(fixture.events.completed.isEmpty)
  }

  @Test("Rows that move while a send is live are carried there by a spring")
  func movedRowsAreCarriedBySprings() throws {
    let fixture = SendFixture()
    defer { fixture.tearDown() }
    let view = fixture.view
    view.sendTransitions.receive(fixture.request, isForeground: true)
    let history = try #require(view.mountedHosts[fixture.historyRow.layoutKey])
    let before = view.sendTransitionScreenY(of: history)

    // The harness's first status row arrives under the bubble.
    let status = TranscriptVirtualRow(id: .startingAgent, content: .startingAgent, estimatedHeight: 32)
    view.sendTransitions.animatingContentShift {
      fixture.replaceRows(inserting: status)
    }

    let moved = before - view.sendTransitionScreenY(of: history)
    #expect(moved > 1)
    let layer = try #require(history.layer)
    let shiftKey = try #require(
      layer.animationKeys()?.first { $0.hasPrefix(TranscriptSendAnimationKeys.shiftPrefix) })
    let shift = try #require(layer.animation(forKey: shiftKey) as? CASpringAnimation)
    #expect(shift.isAdditive)
    #expect(abs((shift.fromValue as? CGFloat ?? 0) - moved) < 0.5)
    // It arrived below the bubble, so it waits for the bubble to land.
    let arrived = try #require(view.mountedHosts[status.layoutKey]?.layer)
    let fade = try #require(arrived.animation(forKey: TranscriptSendAnimationKeys.follower))
    #expect(fade.beginTime > 0)
    // Rows presented away from their model frames stay mounted.
    let mounted = Set(view.mountedHosts.keys)
    view.retireMountedHosts(excluding: [])
    #expect(Set(view.mountedHosts.keys) == mounted)
  }

  @Test("A staged composer snapshot flies into the row and hands off exactly once")
  func stagedSnapshotFliesAndHandsOffOnce() throws {
    let fixture = SendFixture()
    defer { fixture.tearDown() }
    let view = fixture.view
    let session = ObjectIdentifier(fixture)
    view.sendTransitions.session = session
    TranscriptSendStaging.shared.stage(
      session: session, textView: fixture.editor, textRect: fixture.editor.bounds, lineHeight: 17,
      bubble: .gray, theme: Theme(palette: nil))
    #expect(TranscriptSendStaging.shared.hasStage(for: session))

    view.sendTransitions.receive(fixture.request, isForeground: true)
    let target = try #require(view.mountedHosts[fixture.userRow.layoutKey]?.layer)
    // The real row is hidden until the flight lands on it.
    #expect(target.animation(forKey: TranscriptSendAnimationKeys.hide) != nil)
    #expect(fixture.events.started.isEmpty)

    // Layout passes only schedule the flight; it starts on its own turn.
    view.sendTransitions.advance()
    #expect(fixture.events.started.isEmpty)
    view.sendTransitions.startReadyFlights()
    // Flights draw in a click-through child window above the chat.
    let overlayWindow = try #require(fixture.window.childWindows?.first)
    let overlay = try #require(
      overlayWindow.contentView?.subviews.first { $0 is TranscriptSendOverlayView })
    #expect(overlay.subviews.count == 2)  // the row's copy and the composer glyphs
    #expect(!TranscriptSendStaging.shared.hasStage(for: session))
    #expect(fixture.events.started == [fixture.request.token])
    #expect(target.animation(forKey: TranscriptSendAnimationKeys.hide) != nil)
    // AppKit's display pass must not strip the flight's animations: the
    // copy is still in the air after the transaction commits.
    CATransaction.flush()
    fixture.window.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    #expect(fixture.events.completed.isEmpty)
    #expect(overlay.subviews.count == 2)

    view.sendTransitions.interrupt()
    #expect(overlay.subviews.isEmpty)
    #expect(fixture.window.childWindows?.isEmpty != false)
    #expect(target.animation(forKey: TranscriptSendAnimationKeys.hide) == nil)
    #expect(fixture.events.completed == [fixture.request.token])
  }

  @Test("A surface replaced before its flight starts leaves the send for its replacement")
  func replacedSurfaceKeepsTheSend() throws {
    let fixture = SendFixture()
    defer { fixture.tearDown() }
    let view = fixture.view
    let session = ObjectIdentifier(fixture)
    view.sendTransitions.session = session
    TranscriptSendStaging.shared.stage(
      session: session, textView: fixture.editor, textRect: fixture.editor.bounds, lineHeight: 17,
      bubble: .gray, theme: Theme(palette: nil))
    view.sendTransitions.receive(fixture.request, isForeground: true)

    // A new chat's first screen is rebuilt as the send happens.
    view.sendTransitions.interrupt()
    #expect(TranscriptSendStaging.shared.hasStage(for: session))
    #expect(fixture.events.claimed.isEmpty)
    #expect(fixture.events.completed.isEmpty)

    view.sendTransitions.receive(fixture.request, isForeground: true)
    view.sendTransitions.startReadyFlights()
    #expect(fixture.events.started == [fixture.request.token])
    #expect(!TranscriptSendStaging.shared.hasStage(for: session))
  }

  @Test("Reduced motion completes each send immediately and exactly once")
  func reducedMotionCompletesOnce() throws {
    let fixture = SendFixture()
    defer { fixture.tearDown() }
    fixture.view.sendTransitions.reduceMotion = true

    fixture.view.sendTransitions.receive(fixture.request, isForeground: true)
    fixture.view.sendTransitions.receive(fixture.request, isForeground: true)
    fixture.view.sendTransitions.interrupt()

    let target = try #require(fixture.view.mountedHosts[fixture.userRow.layoutKey]?.layer)
    #expect(target.animationKeys() == nil)
    #expect(fixture.events.completed == [fixture.request.token])
  }

  @Test("A surface prewarming behind New Chat shows the landed row as-is")
  func backgroundSurfaceDoesNotAnimate() throws {
    let fixture = SendFixture()
    defer { fixture.tearDown() }

    fixture.view.sendTransitions.receive(fixture.request, isForeground: false)

    let target = try #require(fixture.view.mountedHosts[fixture.userRow.layoutKey]?.layer)
    #expect(target.animationKeys() == nil)
    #expect(fixture.events.claimed.isEmpty)
  }
}

/// A mounted, measured, bottom-pinned transcript whose newest row is an
/// optimistic user message: the moment right after a Send tap.
@MainActor
private final class SendFixture {
  final class Events {
    var claimed: [UInt64] = []
    var started: [UInt64] = []
    var completed: [UInt64] = []
  }

  let view: VirtualizedTranscriptScrollView
  let editor: NSTextView
  let window: NSWindow
  let historyRow: TranscriptVirtualRow
  let userRow: TranscriptVirtualRow
  let request: UserSendAnimationRequest
  let events = Events()
  private var rows: [TranscriptVirtualRow]

  init() {
    _ = NSApplication.shared
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    view = VirtualizedTranscriptScrollView(frame: NSRect(x: 0, y: 100, width: 900, height: 500))
    editor = NSTextView(frame: NSRect(x: 40, y: 20, width: 400, height: 22))
    editor.string = "tell me a joke"
    content.addSubview(view)
    content.addSubview(editor)
    window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = content
    view.isPreparingInitialProjection = false
    view.initialPositionConfigured = true
    view.initialPositionApplied = true

    let user = UserMessage(text: "tell me a joke")
    historyRow = TranscriptVirtualRow(id: .message(UUID()), content: .error("history"), estimatedHeight: 300)
    userRow = TranscriptVirtualRow(id: .message(user.id), content: .optimistic(user), estimatedHeight: 62)
    rows = [
      historyRow,
      userRow,
      TranscriptVirtualRow(id: .bottomSpacer, content: .bottomSpacer(100), estimatedHeight: 100),
    ]
    request = UserSendAnimationRequest(token: 7, messageID: user.id)

    view.rowContent = { row in AnyView(Color.clear.frame(height: row.estimatedHeight)) }
    view.layout()
    replaceRows(inserting: nil)
    view.commitPendingMeasurements()

    let events = events
    view.sendTransitions.claim = { claimed in
      events.claimed.append(claimed.token)
      return true
    }
    view.sendTransitions.onStarted = { events.started.append($0.token) }
    view.sendTransitions.onCompleted = { events.completed.append($0.token) }
  }

  /// Publishes the rows (optionally with `row` inserted above the spacer),
  /// lays them out, and pins the transcript to its newest row.
  func replaceRows(inserting row: TranscriptVirtualRow?) {
    if let row { rows.insert(row, at: rows.count - 1) }
    _ = view.rowSet.replaceRows(rows)
    _ = view.activateMeasurementCacheIfNeeded()
    for row in rows {
      view.measurements.setExact(row.estimatedHeight, for: row.layoutKey)
    }
    view.rebuildDocumentGeometry()
    view.updateMountedRows()
    for host in view.mountedHosts.values { host.prepareForImmediatePresentation() }
    view.scrollToBottom()
  }

  func tearDown() {
    view.sendTransitions.interrupt()
    TranscriptSendStaging.shared.cancel(session: ObjectIdentifier(self))
    view.prepareForDismantle()
    window.contentView = nil
  }
}

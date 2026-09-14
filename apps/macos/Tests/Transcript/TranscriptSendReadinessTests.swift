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
}

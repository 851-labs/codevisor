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
  @Test("An unchanged waiting height wakes the pending flight after host layout")
  func unchangedHeightStartsFlight() throws {
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
    for _ in 0..<3 {
      for host in view.mountedHosts.values { host.prepareForImmediatePresentation() }
      view.commitPendingMeasurements()
    }
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
    host.installRootView(AnyView(Color.clear.frame(height: 15)), knownHeight: nil)
    view.displayFrameRequested = false
    link.isPaused = true
    // Flush only the host. A scroll-view layout or model update would mask
    // the missing wakeup that caused the hold to expire in the recording.
    for _ in 0..<3 { host.prepareForImmediatePresentation() }
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

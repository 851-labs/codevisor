import AppKit
import CodevisorUI
import SwiftUI
import Testing
import TranscriptKit
@testable import TranscriptSurface

@Suite("Native transcript autoscroll", .serialized)
@MainActor
struct TranscriptAutoscrollTests {
  private func row(
    height: CGFloat,
    membership: TranscriptWorkedSectionMembership? = nil
  ) -> TranscriptVirtualRow {
    .init(
      id: .message(UUID()), content: .error("fixture"), estimatedHeight: height,
      workedSection: membership
    )
  }

  private func makeView(rows: [TranscriptVirtualRow]? = nil) -> VirtualizedTranscriptScrollView {
    _ = NSApplication.shared
    let view = VirtualizedTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
    view.isPreparingInitialProjection = false
    view.initialPositionConfigured = true
    view.initialPositionApplied = true
    view.rowContent = { row in AnyView(Color.clear.frame(height: row.estimatedHeight)) }
    view.layout()
    let rows = rows ?? [row(height: 900), row(height: 180)]
    _ = view.rowSet.replaceRows(rows)
    _ = view.activateMeasurementCacheIfNeeded()
    for row in rows {
      view.measurements.setExact(row.estimatedHeight, for: row.layoutKey)
    }
    view.rebuildDocumentGeometry()
    view.layout()
    view.scrollToBottom()
    return view
  }

  private func resize(_ view: VirtualizedTranscriptScrollView, width: CGFloat, height: CGFloat) {
    view.setFrameSize(CGSize(width: width, height: height))
    view.layout()
  }

  @Test("The split header arriving after width reflow keeps the bottom pinned")
  func splitWidthThenHeight() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    resize(view, width: 450, height: 500)
    view.commitPendingMeasurements()
    resize(view, width: 450, height: 468)
    #expect(view.currentDistanceFromBottom() <= 0.5)
    #expect(view.lastBottomState == true)

    // Text measurement can arrive on a later display frame after both sizes.
    let key = view.rows.last!.layoutKey
    view.recordMeasuredHeight(300, for: key)
    view.commitPendingMeasurements()
    #expect(view.currentDistanceFromBottom() <= 0.5)
    #expect(view.lastBottomState == true)
  }

  @Test("A vertical split preserves the bottom through each height change")
  func heightOnlyResize() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    for height: CGFloat in [480, 420, 300, 700] {
      resize(view, width: 900, height: height)
      #expect(view.currentDistanceFromBottom() <= 0.5)
      #expect(view.lastBottomState == true)
    }
  }

  @Test("Resize notifications after a wheel event cannot cancel following")
  func resizeDuringRecentInput() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    view.markRecentUserInput()
    // Exercise the clip notification before NSScrollView.layout(), which is
    // where AppKit first exposes the new split/header size to the observer.
    view.contentView.setFrameSize(CGSize(width: 900, height: 460))
    view.viewportDidScroll()
    #expect(view.followsLatest)
    resize(view, width: 450, height: 460)
    #expect(view.followsLatest)
    #expect(view.currentDistanceFromBottom() <= 0.5)
  }

  @Test("Scrolling up cancels following and resizing preserves the reading position")
  func userScrollWins() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    view.isHandlingUserInput = true
    view.contentView.scroll(to: CGPoint(x: 0, y: view.contentView.bounds.minY - 100))
    view.viewportDidScroll()
    view.isHandlingUserInput = false
    #expect(!view.followsLatest)
    let top = view.contentView.bounds.minY
    resize(view, width: 900, height: 350)
    #expect(view.contentView.bounds.minY == top)
    let key = view.rows.last!.layoutKey
    view.recordMeasuredHeight(300, for: key)
    view.commitPendingMeasurements()
    #expect(view.contentView.bounds.minY == top)
    #expect(view.lastBottomState == false)
  }

  @Test("Subthreshold wheel movement does not silently cancel following")
  func nearBottomRemainsFollowing() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    var followChanges: [Bool] = []
    view.onFollowStateChange = { followChanges.append($0) }
    view.isHandlingUserInput = true
    view.contentView.scroll(to: CGPoint(x: 0, y: view.contentView.bounds.minY - 1))
    view.viewportDidScroll()
    view.isHandlingUserInput = false
    #expect(view.followsLatest)
    #expect(!followChanges.contains(false))
  }

  @Test("A static viewport at the bottom stays there until reflow finishes")
  func staticBottomReflow() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    view.followsLatest = false
    resize(view, width: 450, height: 468)
    view.recordMeasuredHeight(300, for: view.rows.last!.layoutKey)
    view.commitPendingMeasurements()
    #expect(view.currentDistanceFromBottom() <= 0.5)
    #expect(!view.followsLatest)
  }

  @Test("Resizing during native scrolling does not force a bottom jump")
  func liveScrollDuringResize() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    let top = view.contentView.bounds.minY
    view.isLiveScrolling = true
    resize(view, width: 900, height: 350)
    #expect(view.contentView.bounds.minY == top)
    view.isLiveScrolling = false
  }

  @Test("A locked restored reading position survives a split")
  func lockedRestoreDuringResize() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    view.setDistanceFromBottom(180)
    view.lockedRestoreDistance = 180
    resize(view, width: 450, height: 468)
    view.commitPendingMeasurements()
    #expect(view.currentDistanceFromBottom() == 180)
  }

  @Test("Automatic worked collapse follows final measurements", arguments: [false, true])
  func completion(reduceMotion: Bool) {
    let identity = TranscriptWorkedSectionIdentity(messageID: UUID(), kind: .implementation)
    let header = row(
      height: 34,
      membership: .init(identity: identity, role: .header(defaultExpanded: true, isFixedExpanded: true))
    )
    let worked = row(height: 80, membership: .init(identity: identity, role: .content))
    let answer = row(height: 120)
    let history = row(height: 900)
    let view = makeView(rows: [history, header, worked, answer])
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = view
    defer {
      view.prepareForDismantle()
      window.contentView = nil
    }
    view.reduceMotion = reduceMotion
    let settledHeader = TranscriptVirtualRow(
      id: header.id, content: header.content, estimatedHeight: header.estimatedHeight,
      workedSection: .init(
        identity: identity, role: .header(defaultExpanded: false, isFixedExpanded: false)
      )
    )
    _ = view.applyRows([history, settledHeader, answer], layoutFingerprintChanged: false)
    if !reduceMotion {
      #expect(!view.disclosureCollapsePresentations.isEmpty)
      #expect(
        view.mountedHosts[answer.layoutKey]?.layer?.animation(
          forKey: VirtualizedTranscriptScrollView.disclosureCollapseAnimationKey
        ) == nil
      )
    }
    // The final answer becomes taller during the former 450 ms anchor hold.
    view.recordMeasuredHeight(420, for: answer.layoutKey)
    view.commitPendingMeasurements()
    #expect(view.currentDistanceFromBottom() <= 0.5)
    #expect(view.lastBottomState == true)
    #expect(view.followsLatest)
  }

  @Test("Clicking a disclosure deliberately keeps its viewport stationary")
  func manualDisclosureRemainsAnchored() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    let top = view.contentView.bounds.minY
    let key = view.rows.last!.layoutKey
    view.performAnchoredDisclosureChange(in: key) {
      view.recordMeasuredHeight(400, for: key)
      view.commitPendingMeasurements()
    }
    #expect(view.contentView.bounds.minY == top)
    #expect(view.currentDistanceFromBottom() > 2)
    #expect(view.lastBottomState == false)
  }
}

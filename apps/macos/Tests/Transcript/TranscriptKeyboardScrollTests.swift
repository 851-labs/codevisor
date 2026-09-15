import AppKit
import CodevisorUI
import SwiftUI
import Testing
import TranscriptKit
@testable import TranscriptSurface

@Suite("Native transcript keyboard scrolling")
@MainActor
struct TranscriptKeyboardScrollTests {
  private func makeView(rowCount: Int = 20, composerHeight: CGFloat = 0) -> VirtualizedTranscriptScrollView {
    _ = NSApplication.shared
    let view = VirtualizedTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
    view.isPreparingInitialProjection = false
    view.initialPositionConfigured = true
    view.initialPositionApplied = true
    view.verticalLineScroll = 24
    view.verticalPageScroll = 30
    view.rowContent = { AnyView(Color.clear.frame(height: $0.estimatedHeight)) }
    view.layout()
    var rows = (0..<rowCount).map { index in
      TranscriptVirtualRow(id: .message(UUID()), content: .error("Row \(index)"), estimatedHeight: 200)
    }
    if composerHeight > 0 {
      rows.append(.init(id: .bottomSpacer, content: .bottomSpacer(composerHeight), estimatedHeight: composerHeight))
    }
    _ = view.rowSet.replaceRows(rows)
    _ = view.activateMeasurementCacheIfNeeded()
    for row in rows {
      view.measurements.setExact(row.estimatedHeight, for: row.layoutKey)
    }
    _ = view.initialPresentationGate.resolve(
      isHydrating: false, requiredKeys: [], resolvedKeys: [], hasPendingMeasurements: false)
    view.rebuildDocumentGeometry()
    view.layout()
    view.scrollToBottom()
    return view
  }

  private func press(
    _ code: UInt16, character: String, in view: VirtualizedTranscriptScrollView,
    modifiers: NSEvent.ModifierFlags = [.function, .numericPad], isRepeat: Bool = false
  ) {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
      isARepeat: isRepeat, keyCode: code)!
    view.keyDown(with: event)
  }

  @Test("Page keys move by a viewport with overlap and update follow intent")
  func pageKeys() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    let bottom = view.contentView.bounds.minY
    let page = view.contentView.bounds.height - view.verticalPageScroll

    press(116, character: "\u{f72c}", in: view)
    #expect(abs(view.contentView.bounds.minY - (bottom - page)) < 0.5)
    #expect(!view.followsLatest)
    #expect(view.lastStableScrollState?.followMode == .staticPosition)
    let readingPosition = view.contentView.bounds.minY
    view.recordMeasuredHeight(260, for: view.rows.last!.layoutKey)
    view.commitPendingMeasurements()
    #expect(abs(view.contentView.bounds.minY - readingPosition) < 0.5)

    press(121, character: "\u{f72d}", in: view)
    #expect(abs(view.contentView.bounds.minY - (readingPosition + page)) < 0.5)
    press(121, character: "\u{f72d}", in: view, isRepeat: true)
    #expect(view.currentDistanceFromBottom() < 0.5)
    #expect(view.followsLatest)
    #expect(view.lastStableScrollState?.followMode == .followingLatest)
  }

  @Test("Home mounts the first rows and requests history; End returns to the latest rows")
  func homeAndEnd() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    view.hasOlderHistory = true
    var historyRequests = 0
    view.onNearTop = {
      historyRequests += 1; return true
    }
    view.lockedRestoreDistance = 100
    view.bottomJumpGate.begin()

    press(115, character: "\u{f729}", in: view)
    #expect(view.contentView.bounds.minY == 0)
    #expect(!view.followsLatest)
    #expect(view.lockedRestoreDistance == nil)
    #expect(!view.bottomJumpGate.isActive)
    #expect(historyRequests == 1)
    #expect(view.mountedHosts[view.rows.first!.layoutKey] != nil)
    #expect(view.lastStableScrollState?.virtualTranscript?.viewportAnchor == view.currentViewportAnchor())

    press(119, character: "\u{f72b}", in: view)
    #expect(view.currentDistanceFromBottom() < 0.5)
    #expect(view.followsLatest)
    #expect(view.mountedHosts[view.rows.last!.layoutKey] != nil)
    press(119, character: "\u{f72b}", in: view, isRepeat: true)
    #expect(view.currentDistanceFromBottom() < 0.5)
  }

  @Test("Arrow keys scroll a line, repeat, and clamp at the document edges")
  func arrowKeys() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    let bottom = view.contentView.bounds.minY
    press(126, character: "\u{f700}", in: view)
    press(126, character: "\u{f700}", in: view, isRepeat: true)
    #expect(abs(view.contentView.bounds.minY - (bottom - 48)) < 0.5)
    #expect(!view.followsLatest)
    press(125, character: "\u{f701}", in: view)
    #expect(abs(view.contentView.bounds.minY - (bottom - 24)) < 0.5)

    press(115, character: "\u{f729}", in: view)
    press(126, character: "\u{f700}", in: view)
    #expect(view.contentView.bounds.minY == 0)
    press(119, character: "\u{f72b}", in: view)
    press(125, character: "\u{f701}", in: view)
    #expect(view.contentView.bounds.minY == bottom)
  }

  @Test("Short transcripts stay in bounds for every navigation key")
  func shortTranscript() {
    let view = makeView(rowCount: 1)
    defer { view.prepareForDismantle() }
    for (code, character): (UInt16, String) in [
      (115, "\u{f729}"), (116, "\u{f72c}"), (119, "\u{f72b}"),
      (121, "\u{f72d}"), (125, "\u{f701}"), (126, "\u{f700}"),
    ] {
      press(code, character: character, in: view)
      #expect(view.contentView.bounds.minY == 0)
      #expect(view.followsLatest)
    }
  }

  @Test("Navigation waits until the initial transcript is visible")
  func initialPresentation() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    view.initialPresentationGate = TranscriptInitialPresentationGate()
    let top = view.contentView.bounds.minY
    press(115, character: "\u{f729}", in: view)
    #expect(view.contentView.bounds.minY == top)
    #expect(view.followsLatest)
    #expect(!view.isHandlingUserInput)
  }

  @Test("Paging keeps overlap above the composer overlay")
  func composerOverlay() {
    let view = makeView(composerHeight: 120)
    defer { view.prepareForDismantle() }
    let bottom = view.contentView.bounds.minY
    press(116, character: "\u{f72c}", in: view)
    #expect(abs(view.contentView.bounds.minY - (bottom - 350)) < 0.5)
    press(121, character: "\u{f72d}", in: view)
    #expect(view.currentDistanceFromBottom() < 0.5)
  }
}

import AppKit
import CodevisorUI
import SwiftUI
import Testing
import TranscriptKit
@testable import TranscriptSurface

@Suite("Native transcript under the bot header")
@MainActor
struct TranscriptTopInsetTests {
  private static let chromeHeight: CGFloat = 74

  private func makeView() -> VirtualizedTranscriptScrollView {
    _ = NSApplication.shared
    let view = VirtualizedTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
    view.isPreparingInitialProjection = false
    view.initialPositionConfigured = true
    view.initialPositionApplied = true
    view.verticalPageScroll = 30
    view.rowContent = { AnyView(Color.clear.frame(height: $0.estimatedHeight)) }
    view.layout()
    let rows = (0..<20).map { index in
      TranscriptVirtualRow(id: .message(UUID()), content: .error("Row \(index)"), estimatedHeight: 200)
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

  private func extendUnderChrome(_ view: VirtualizedTranscriptScrollView) {
    view.setFrameSize(NSSize(width: view.frame.width, height: view.frame.height + Self.chromeHeight))
    view.topChromeHeight = Self.chromeHeight
    view.layout()
  }

  @Test("The newest rows stay pinned and the first row clears the header")
  func firstRowClearsChrome() {
    let view = makeView()
    defer { view.prepareForDismantle() }

    extendUnderChrome(view)

    #expect(view.topContentInset == Self.chromeHeight)
    #expect(view.currentDistanceFromBottom() < 0.5)
    view.setViewportTop(0)
    let firstRowOffset = view.rowFrame(at: 0).minY - view.contentView.bounds.minY
    #expect(firstRowOffset == Self.chromeHeight + VirtualizedTranscriptScrollView.topPadding)
  }

  @Test("A reading position keeps the same row at the visible top when the header appears")
  func readingPositionSurvivesChrome() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    view.followsLatest = false
    view.setViewportTop(1_000)
    let anchor = view.currentViewportAnchor()

    extendUnderChrome(view)

    #expect(view.currentViewportAnchor() == anchor)
    #expect(view.unobstructedViewport.minY == view.contentView.bounds.minY + Self.chromeHeight)
  }

  @Test("A press on the header band reaches the title bar, not the transcript")
  func headerBandHitsTitlebar() {
    let view = makeView()
    defer { view.prepareForDismantle() }
    let window = host(view)

    #expect(window.contentView?.hitTest(Self.bandPoint(in: view)) === view.titlebarRegion)
    let below = window.contentView?.hitTest(Self.belowBandPoint(in: view))
    #expect(below?.isDescendant(of: view.contentView) == true)
  }

  @Test("A mouse-down on the header band starts no selection and leaves the transcript still")
  func headerBandPressLeavesTranscriptStill() throws {
    let view = makeView()
    defer { view.prepareForDismantle() }
    let window = host(view)
    var titlebarPresses: [Int] = []
    view.titlebarRegion.press = { event, _ in titlebarPresses.append(event.clickCount) }
    let origin = view.contentView.bounds.origin

    let point = Self.bandPoint(in: view)
    let hit = try #require(window.contentView?.hitTest(point))
    hit.mouseDown(with: try Self.mouseEvent(.leftMouseDown, at: point, in: window))

    #expect(titlebarPresses == [1])
    #expect(view.textSelection.selection == nil)
    #expect(view.textSelection.autoScrollTask == nil)
    #expect(view.contentView.bounds.origin == origin)
  }

  @Test("A selection dragged from the transcript over the header band still scrolls up")
  func selectionDraggedOverBandScrollsUp() throws {
    let view = makeView()
    defer { view.prepareForDismantle() }
    let window = host(view)
    let document = view.transcriptDocumentView
    let start = Self.belowBandPoint(in: view)
    document.mouseDown(with: try Self.mouseEvent(.leftMouseDown, at: start, in: window))
    try #require(view.textSelection.isDragging)
    let originY = view.contentView.bounds.minY

    let band = Self.bandPoint(in: view)
    document.mouseDragged(with: try Self.mouseEvent(.leftMouseDragged, at: band, in: window))
    view.selectionAutoScrollTick()

    #expect(view.contentView.bounds.minY < originY)
    document.mouseUp(with: try Self.mouseEvent(.leftMouseUp, at: band, in: window))
    #expect(view.textSelection.autoScrollTask == nil)
  }

  @Test(
    "A title bar double-click follows the system setting",
    arguments: [
      ("Maximize", false, TitlebarDoubleClickAction.zoom),
      ("Minimize", false, .minimize),
      ("None", true, .doNothing),
      (nil, false, .zoom),
      (nil, true, .minimize),
    ] as [(String?, Bool, TitlebarDoubleClickAction)]
  )
  func doubleClickFollowsSystemSetting(
    setting: String?, legacyMinimizes: Bool, expected: TitlebarDoubleClickAction
  ) {
    #expect(TitlebarDoubleClickAction(setting: setting, legacyMinimizes: legacyMinimizes) == expected)
  }

  private func host(_ view: VirtualizedTranscriptScrollView) -> NSWindow {
    extendUnderChrome(view)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView?.addSubview(view)
    view.layout()
    return window
  }

  private static func bandPoint(in view: NSView) -> NSPoint {
    NSPoint(x: view.frame.midX, y: view.frame.maxY - chromeHeight / 2)
  }

  private static func belowBandPoint(in view: NSView) -> NSPoint {
    NSPoint(x: view.frame.midX, y: view.frame.maxY - chromeHeight - 40)
  }

  private static func mouseEvent(
    _ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow
  ) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1
      ))
  }
}

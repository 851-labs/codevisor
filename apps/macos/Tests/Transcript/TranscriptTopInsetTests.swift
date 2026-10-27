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
}

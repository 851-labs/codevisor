import CodevisorUI
import Observation
import StreamMarkdown
import SwiftUI
import Testing
import TranscriptKit
import UIKit
@testable import TranscriptSurface

@MainActor
@Suite("iOS transcript placed content geometry")
struct TranscriptContentLayoutTests {
  @Observable
  final class Content {
    var text = "Short text"
    var width: CGFloat = 320
  }

  private struct ContentView: View {
    let content: Content
    var body: some View {
      SelectableTextView(
        attributedText: NSAttributedString(
          string: content.text, attributes: [.font: UIFont.systemFont(ofSize: 17)]), fillsWidth: false
      )
      .environment(\.streamMarkdownTextLayoutWidth, content.width)
      .frame(width: content.width, alignment: .topLeading)
    }
  }

  @Test("The placed text reports its full height in the same native layout")
  func contentAndWidthChanges() throws {
    let content = Content()
    let controller = TranscriptContentHostingController(rootView: AnyView(ContentView(content: content)))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 700))
    let parent = UIViewController()
    window.rootViewController = parent
    window.isHidden = false
    parent.addChild(controller)
    parent.view.addSubview(controller.view)
    controller.didMove(toParent: parent)
    controller.view.frame = CGRect(x: 0, y: 0, width: content.width, height: 100)
    var heights: [CGFloat] = []
    controller.onLaidOutHeightChange = { heights.append($0) }
    defer {
      controller.willMove(toParent: nil)
      controller.view.removeFromSuperview()
      controller.removeFromParent()
      window.isHidden = true
      window.rootViewController = nil
    }
    controller.view.layoutIfNeeded()
    let initial = try #require(heights.last)
    content.text = String(repeating: "A growing transcript sentence. ", count: 40)
    controller.invalidateContentSize(forceReport: true)
    controller.viewDidLayoutSubviews()
    controller.view.layoutIfNeeded()
    let wide = try #require(heights.last)
    #expect(wide > initial)
    try expectTextFits(controller, height: wide, text: content.text)

    content.width = 220
    controller.view.frame.size.width = 220
    controller.invalidateContentSize()
    controller.view.layoutIfNeeded()
    let narrow = try #require(heights.last)
    #expect(narrow > wide)
    try expectTextFits(controller, height: narrow, text: content.text)

    let reports = heights.count
    for y: CGFloat in [20, 40, 80] {
      controller.view.frame.origin.y = y
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
    }
    #expect(heights.count == reports)
  }

  @Test("Visible height corrections during momentum preserve the native scroll offset")
  func measurementsDuringDeceleration() throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
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
    let rows = (0..<8).map {
      TranscriptVirtualRow(id: .message(UUID()), content: .error("Row \($0)"), estimatedHeight: 180)
    }
    view.rowContent = { AnyView(Color.clear.frame(height: $0.estimatedHeight)) }
    view.initialPositionApplied = true
    view.initialPositionConfigured = true
    view.isPreparingInitialProjection = false
    view.followsLatest = false
    _ = view.rowSet.replaceRows(rows)
    for row in rows { view.measurements.setExact(180, for: row.layoutKey) }
    view.rebuildDocumentGeometry()
    view.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
    view.updateMountedRows()
    view.measurementCommitGate.draggingDidEnd(willDecelerate: true)
    let firstVisible = try #require(view.firstVisibleRowForMeasurementCommit)
    try #require(firstVisible > 0)
    let above = rows[firstVisible - 1]
    let visible = rows[firstVisible]
    view.mountRow(at: firstVisible - 1, parent: parent, requiresImmediatePresentation: true)
    try #require(view.mountedHosts[above.layoutKey] != nil)
    let host = try #require(view.mountedHosts[visible.layoutKey])
    let offset = view.contentOffset
    for row in [above, visible] {
      view.recordMeasuredHeight(
        .init(
          key: row.layoutKey, revision: row.measurementRevision,
          rowWidthHalfPoints: Int((view.effectiveRowWidth * 2).rounded()), height: 260))
    }
    #expect(view.allowsMeasurementCommit)
    view.commitPendingMeasurements()

    #expect(view.measurements[visible.layoutKey] == 260)
    #expect(host.frame.height == 260)
    #expect(host.layer.mask?.frame.height == 260)
    #expect(view.contentOffset == offset)
    #expect(view.measurements[above.layoutKey] == 180)
    #expect(view.pendingMeasurements[above.layoutKey]?.height == 260)
    #expect(!view.allowsMeasurementCommit)

    view.measurementCommitGate.interactionDidEnd()
    view.commitPendingMeasurements()
    #expect(view.measurements[above.layoutKey] == 260)
    #expect(view.pendingMeasurements.isEmpty)
  }

  private func expectTextFits(_ controller: TranscriptContentHostingController, height: CGFloat, text: String) throws {
    func textView(in view: UIView) -> SelectableTextKitView? {
      if let text = view as? SelectableTextKitView { return text }
      return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
    let view = try #require(textView(in: controller.view))
    #expect(view.text == text)
    view.layoutManager.ensureLayout(for: view.textContainer)
    let rect = view.convert(view.layoutManager.usedRect(for: view.textContainer), to: controller.view)
    #expect(rect.minY >= 0)
    #expect(rect.maxY <= height)
  }
}

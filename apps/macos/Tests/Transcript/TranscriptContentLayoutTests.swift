import AppKit
import CodevisorUI
import Observation
import StreamMarkdown
import SwiftUI
import Testing
import TranscriptKit
@testable import TranscriptSurface

@MainActor
@Suite("Transcript placed content geometry")
struct TranscriptContentLayoutTests {
  @Observable
  final class Content {
    var text = "Short text"
    var width: CGFloat = 320
  }

  private struct ContentView: View {
    let content: Content

    var body: some View {
      SelectableTextView(content.text)
        .environment(\.streamMarkdownTextLayoutWidth, content.width)
        .frame(width: content.width, alignment: .topLeading)
    }
  }

  @Test("A layout callback before SwiftUI reconciliation cannot lock in the old height")
  func lateContentLayout() throws {
    try withController { controller, content, heights in
      let initial = try #require(heights.values.last)
      content.text = String(repeating: "A growing transcript sentence. ", count: 40)
      controller.invalidateContentSize(forceReport: true)
      // The native callback can precede SwiftUI's observed-content update.
      // The old sizing probe consumed its invalidation here and kept 16pt
      // even after the actual text grew to hundreds of points.
      controller.viewDidLayout()
      controller.view.layoutSubtreeIfNeeded()

      let height = try #require(heights.values.last)
      #expect(height > initial)
      try expectTextFits(controller, height: height, text: content.text)

      content.text = "Short again"
      controller.view.layoutSubtreeIfNeeded()
      #expect(heights.values.last == initial)
    }
  }

  @Test("A cached height is corrected by the actual placed layout")
  func cachedHeightIsVerified() throws {
    try withController { controller, content, heights in
      let cached = try #require(heights.values.last)
      content.text = String(repeating: "Content changed while the row was retained. ", count: 30)
      controller.useKnownContentHeight(cached)
      controller.installRootView(AnyView(ContentView(content: content)))
      controller.view.layoutSubtreeIfNeeded()

      let height = try #require(heights.values.last)
      #expect(height > cached)
      try expectTextFits(controller, height: height, text: content.text)
    }
  }

  @Test("Width changes reflow the row and unchanged layouts do not report again")
  func widthChangeAndStableLayout() throws {
    try withController { controller, content, heights in
      content.text = String(repeating: "A transcript sentence that wraps. ", count: 20)
      controller.view.layoutSubtreeIfNeeded()
      let wide = try #require(heights.values.last)
      content.width = 220
      controller.view.setFrameSize(NSSize(width: 220, height: 100))
      controller.invalidateContentSize()
      controller.view.layoutSubtreeIfNeeded()
      let narrow = try #require(heights.values.last)
      #expect(narrow > wide)
      try expectTextFits(controller, height: narrow, text: content.text)

      let reports = heights.values.count
      for y: CGFloat in [20, 40, 80] {
        controller.view.setFrameOrigin(NSPoint(x: 0, y: y))
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
      }
      #expect(heights.values.count == reports)
    }
  }

  @Test("A native settled renderer verifies a height inherited from another surface")
  func nativeRendererVerifiesCachedHeight() {
    let host = TranscriptMarkdownRowHost(frame: NSRect(x: 0, y: 0, width: 320, height: 16))
    let text = String(repeating: "A settled transcript sentence. ", count: 40)
    let chunk = TranscriptMarkdownChunk(
      messageID: UUID(), sourceID: "response", ordinal: 0,
      blocks: MarkdownParser().parse(text), documentSource: text,
      lifecycle: .settled, container: .assistantResponse
    )
    var heights: [CGFloat] = []
    host.onHeightChange = { heights.append($0) }
    let style = TranscriptMarkdownRowStyle(markdown: .default, appTheme: .system)
    host.setContent(chunk, streamID: "response", style: style, linkAction: nil, knownHeight: 16)
    #expect((heights.last ?? 0) > 16)
    #expect(host.isPresentationReady)
    let reports = heights.count
    // Reusing the same prepared layout must not cause another height commit.
    host.setContent(chunk, streamID: "response", style: style, linkAction: nil, knownHeight: heights.last)
    #expect(heights.count == reports)
  }

  private final class Heights {
    var values: [CGFloat] = []
  }

  private func withController(
    _ check: (TranscriptContentHostingController, Content, Heights) throws -> Void
  ) throws {
    _ = NSApplication.shared
    let content = Content()
    let controller = TranscriptContentHostingController(rootView: AnyView(ContentView(content: content)))
    let frame = NSRect(x: 0, y: 0, width: content.width, height: 100)
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentViewController = controller
    controller.view.frame = frame
    let heights = Heights()
    controller.onLaidOutHeightChange = { heights.values.append($0) }
    defer { window.contentViewController = nil }
    controller.view.layoutSubtreeIfNeeded()
    try check(controller, content, heights)
  }

  private func expectTextFits(_ controller: TranscriptContentHostingController, height: CGFloat, text: String) throws {
    func textView(in view: NSView) -> SelectableTextKitView? {
      if let text = view as? SelectableTextKitView { return text }
      return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
    let view = try #require(textView(in: controller.view))
    #expect(view.string == text)
    let manager = try #require(view.layoutManager)
    let container = try #require(view.textContainer)
    manager.ensureLayout(for: container)
    let rect = view.convert(manager.usedRect(for: container), to: controller.view)
    #expect(rect.minY >= 0)
    #expect(rect.maxY <= height)
  }
}

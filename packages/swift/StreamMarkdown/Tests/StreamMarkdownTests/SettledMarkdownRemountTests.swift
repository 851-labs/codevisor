import AppKit
@testable import StreamMarkdown
import Testing

@MainActor
@Suite("Settled native Markdown remounts")
struct SettledMarkdownRemountTests {
  @Test("Prose remounted at an unchanged height announces that it is ready again")
  func remountedPreparedProseAnnouncesReadiness() async {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.appearance = NSAppearance(named: .aqua)
    let blocks: [MarkdownBlock] = [
      .paragraph(String(repeating: "A row the transcript mounts, parks and mounts again. ", count: 6))
    ]
    func mountedView(_ streamID: String) -> SettledMarkdownView {
      let view = SettledMarkdownView()
      view.setContent(blocks: blocks, theme: .default, streamID: streamID, linkAction: nil)
      window.contentView?.addSubview(view)
      return view
    }
    let streamID = "remounted-ready-\(UUID().uuidString)"
    _ = mountedView(streamID).contentHeight(forWidth: 420)
    await StaticTextCache.shared.waitUntilIdle()

    let view = mountedView(streamID)
    let prepared = view.contentHeight(forWidth: 420)
    #expect(view.isContentReady)
    var contentChanges = 0
    view.onContentHeightChange = { contentChanges += 1 }

    view.removeFromSuperview()
    window.contentView?.addSubview(view)
    #expect(view.contentHeight(forWidth: 420) == prepared)
    #expect(!view.isContentReady)

    view.frame = NSRect(x: 0, y: 0, width: 420, height: prepared)
    view.layoutSubtreeIfNeeded()

    #expect(view.isContentReady)
    #expect(contentChanges == 1)
    #expect(view.contentHeight(forWidth: 420) == prepared)
  }
}

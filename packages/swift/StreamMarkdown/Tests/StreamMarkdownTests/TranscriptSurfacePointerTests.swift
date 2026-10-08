import AppKit
@testable import StreamMarkdown
import Testing

@MainActor
@Suite("Transcript surface pointer")
struct TranscriptSurfacePointerTests {
  @Test("A link beneath another view is not hovered")
  func coveredLinkIsNotHovered() {
    let text = NSMutableAttributedString(
      string: "Read the docs",
      attributes: [.font: NSFont.preferredFont(forTextStyle: .body)]
    )
    let linkRange = NSRange(location: 5, length: 8)
    text.addAttribute(.link, value: URL(string: "https://example.com")!, range: linkRange)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    let view = SelectableTextKitView()
    view.setContent(text)
    view.setFrameSize(NSSize(width: 320, height: view.contentHeight(forWidth: 320)))
    window.contentView!.addSubview(view)
    // A sibling added later is frontmost, like the composer floating over
    // a transcript scrolled beneath it.
    let cover = NSView(frame: view.frame)
    window.contentView!.addSubview(cover)

    guard let layoutManager = view.layoutManager, let textContainer = view.textContainer else {
      Issue.record("Missing TextKit stack")
      return
    }
    layoutManager.ensureLayout(for: textContainer)
    let linkRect = layoutManager.boundingRect(
      forGlyphRange: layoutManager.glyphRange(forCharacterRange: linkRange, actualCharacterRange: nil),
      in: textContainer
    )
    let point = view.convert(
      NSPoint(
        x: linkRect.midX + view.textContainerOrigin.x,
        y: linkRect.midY + view.textContainerOrigin.y
      ),
      to: nil
    )
    let move = NSEvent.mouseEvent(
      with: .mouseMoved,
      location: point,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 0,
      pressure: 0
    )!

    view.mouseMoved(with: move)
    #expect(view.hoveredLinkRange == nil)

    cover.removeFromSuperview()
    view.mouseMoved(with: move)
    #expect(view.hoveredLinkRange == linkRange)
  }
}

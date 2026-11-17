import AppKit
@testable import MarkdownCore
@testable import StreamMarkdown
import Testing

@MainActor
@Suite("Settled prose width")
struct SettledMarkdownWidthTests {
  private let window: NSWindow = {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.appearance = NSAppearance(named: .aqua)
    return window
  }()

  @Test("Prose shows text wrapped to its own width in the same layout pass")
  func proseRewrapsInTheSameLayoutPass() throws {
    let view = mountedProse()

    for width: CGFloat in [520, 300] {
      view.frame = NSRect(x: 0, y: 0, width: width, height: view.contentHeight(forWidth: width))
      view.layoutSubtreeIfNeeded()

      let lines = try shownLines(in: view)
      #expect(!lines.isEmpty)
      #expect(lines.allSatisfy { $0.maxX <= width + 0.5 })
      #expect(lines.allSatisfy { $0.maxY <= view.frame.height + 0.5 })
    }
  }

  @Test("Prose shows a finished picture at its measured height in the same pass")
  func pictureIsReadyAtTheMeasuredHeight() throws {
    let view = mountedProse()
    var heightChanges = 0
    view.onContentHeightChange = { heightChanges += 1 }

    let measured = view.contentHeight(forWidth: 420)
    view.frame = NSRect(x: 0, y: 0, width: 420, height: measured)
    view.layoutSubtreeIfNeeded()

    let shown = try #require(try surface(in: view).prepared)
    #expect(shown.image != nil)
    #expect(shown.size.height == measured)
    #expect(heightChanges == 0)
  }

  private func mountedProse() -> SettledMarkdownView {
    let view = SettledMarkdownView()
    view.setContent(
      fragment: MarkdownFragment(blocks: [
        .paragraph(
          MarkdownParser().parseInline(
            String(repeating: "Prose with `inline code` that wraps across several lines at every width. ", count: 6)
          )
        )
      ]),
      theme: .default,
      streamID: "settled-width-\(UUID().uuidString)",
      linkAction: nil
    )
    window.contentView?.addSubview(view)
    return view
  }

  private func shownLines(in view: SettledMarkdownView) throws -> [NSRect] {
    let surface = try surface(in: view)
    return surface.transcriptTextRects(for: NSRange(location: 0, length: surface.transcriptText.length))
      .map { surface.convert($0, to: view) }
  }

  private func surface(in view: NSView) throws -> StaticTextSurfaceView {
    try #require(allSubviews(of: view).lazy.compactMap { $0 as? StaticTextSurfaceView }.first)
  }

  private func allSubviews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(allSubviews)
  }
}

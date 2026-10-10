#if canImport(AppKit)
  import AppKit
  import Testing
  @testable import CodevisorUI

  @Suite("Native plain output view")
  @MainActor
  struct NativePlainOutputViewTests {
    @Test("One selectable text surface renders the complete output")
    func usesOneTextSurface() {
      let output = "first\nsecond\nthird"
      let scrollView = makeScrollView(text: output)

      #expect(countTextViews(in: scrollView) == 1)
      #expect(scrollView.outputTextView.string == output)
      #expect(scrollView.contentFittingSize.height > 0)
      #expect(
        scrollView.fitContent(toViewportWidth: 500).height
          == scrollView.contentFittingSize.height
      )
      #expect(!scrollView.hasVerticalScroller)
    }

    @Test("Streaming output appends in the existing native surface")
    func appendsInExistingSurface() {
      let scrollView = makeScrollView(text: "first")
      let textView = scrollView.outputTextView
      let storage = textView.textStorage

      scrollView.setContent(
        text: "first\nsecond\nthird",
        theme: .system,
        followsTail: true
      )

      #expect(scrollView.outputTextView === textView)
      #expect(scrollView.outputTextView.textStorage === storage)
      #expect(scrollView.outputTextView.string == "first\nsecond\nthird")
    }

    @Test("A shell call reads as a terminal: its command's line, then the output streaming under it")
    func echoesCommand() {
      let scrollView = NativePlainOutputScrollView()
      scrollView.setContent(text: "", command: "cat notes.txt", theme: .system, followsTail: true)
      #expect(scrollView.outputTextView.string == "cat notes.txt")

      let storage = scrollView.outputTextView.textStorage
      scrollView.setContent(text: "hello", command: "cat notes.txt", theme: .system, followsTail: true)
      scrollView.setContent(text: "hello\nworld", command: "cat notes.txt", theme: .system, followsTail: true)
      #expect(scrollView.outputTextView.textStorage === storage)
      #expect(scrollView.outputTextView.string == "cat notes.txt\nhello\nworld")

      func color(at location: Int) -> NSColor? {
        storage?.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
      }
      // The command keeps the primary color; the output steps back.
      #expect(color(at: 0) != color(at: ("cat notes.txt\n" as NSString).length))
      #expect(
        color(at: ("cat notes.txt\nhello\n" as NSString).length) == color(at: ("cat notes.txt\n" as NSString).length))

      scrollView.setContent(text: "hello\nworld", command: "cat other.txt", theme: .system, followsTail: true)
      #expect(scrollView.outputTextView.string == "cat other.txt\nhello\nworld")
    }

    @Test("Output content has compact vertical breathing room")
    func usesVerticalContentInsets() {
      let scrollView = makeScrollView(text: "output")

      #expect(scrollView.outputTextView.textContainerInset.height == 4)
      #expect(scrollView.contentFittingSize.height > 8)
    }

    @Test("Long lines scroll horizontally without wrapping")
    func horizontallyScrollsOverflow() {
      let output = String(repeating: "wide-output-", count: 50)
      let scrollView = makeScrollView(text: output)
      let naturalWidth = scrollView.contentFittingSize.width

      _ = scrollView.fitContent(toViewportWidth: 120)

      #expect(naturalWidth > 120)
      #expect(scrollView.hasHorizontalScroller)
      #expect(scrollView.outputTextView.frame.width == naturalWidth)
    }

    @Test("Thousands of lines stay in one bounded viewport")
    func largeOutputUsesBoundedViewport() {
      let output = (0..<5_000).map { "line \($0)" }.joined(separator: "\n")
      let scrollView = makeScrollView(text: output)
      let visible = scrollView.fitContent(toViewportWidth: 500)

      #expect(countTextViews(in: scrollView) == 1)
      #expect(scrollView.contentFittingSize.height > DiffViewportMetrics.maximumHeight)
      #expect(visible.height == DiffViewportMetrics.maximumHeight)
      #expect(scrollView.hasVerticalScroller)
      #expect(scrollView.outputTextView.frame.height == scrollView.contentFittingSize.height)
    }

    @Test("Vertical scrolling hands off at both output boundaries")
    func verticalScrollingChainsAtBoundaries() {
      let output = (0..<100).map { "line \($0)" }.joined(separator: "\n")
      let scrollView = makeScrollView(text: output)
      let visibleSize = scrollView.fitContent(toViewportWidth: 500)
      scrollView.frame = CGRect(origin: .zero, size: visibleSize)
      scrollView.layoutSubtreeIfNeeded()

      #expect(!scrollView.canConsumeVerticalDelta(1))
      #expect(scrollView.canConsumeVerticalDelta(-1))

      let bottomY = scrollView.contentFittingSize.height - visibleSize.height
      scrollView.contentView.scroll(to: CGPoint(x: 0, y: bottomY))
      scrollView.reflectScrolledClipView(scrollView.contentView)

      #expect(scrollView.canConsumeVerticalDelta(1))
      #expect(!scrollView.canConsumeVerticalDelta(-1))
    }

    private func makeScrollView(text: String) -> NativePlainOutputScrollView {
      let scrollView = NativePlainOutputScrollView()
      scrollView.setContent(text: text, theme: .system, followsTail: false)
      return scrollView
    }

    private func countTextViews(in view: NSView) -> Int {
      (view is NSTextView ? 1 : 0)
        + view.subviews.reduce(0) { $0 + countTextViews(in: $1) }
    }
  }
#endif

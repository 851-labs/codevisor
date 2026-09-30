#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import Testing
  import TranscriptKit
  @testable import CodevisorUI

  @Suite("Native diff view")
  @MainActor
  struct NativeDiffViewTests {
    @Test("One exact-height text surface renders every row")
    func usesOneExactHeightTextSurface() {
      let rows = LineDiff.rows(
        old: "let old = 1\n",
        new: "let new = 2\n\nprint(new)\n"
      )
      let scrollView = makeScrollView(rows: rows)
      let natural = scrollView.contentFittingSize
      let visible = scrollView.fitContent(toViewportWidth: natural.width)

      let metrics = NativeDiffMetrics(rows: rows)
      let textView = scrollView.diffTextView

      #expect(countTextViews(in: scrollView) == 1)
      #expect(natural.height == CGFloat(rows.count) * metrics.rowHeight + metrics.verticalPadding * 2)
      #expect(visible.height == natural.height)
      #expect(!scrollView.hasVerticalScroller)
      #expect(textView.frame.height == natural.height)
      // Rows sit inside the padding; the edge rows' fills cover it.
      #expect(textView.rowRect(at: 0)?.minY == metrics.verticalPadding)
      #expect(textView.rowRect(at: rows.count - 1)?.maxY == natural.height - metrics.verticalPadding)
      #expect(textView.rowFillRect(at: 0)?.minY == 0)
      #expect(textView.rowFillRect(at: rows.count - 1)?.maxY == natural.height)
    }

    @Test("Edge rows fill any slack so a trailing change is tinted to the bottom edge")
    func edgeRowsFillSlack() throws {
      let rows = LineDiff.rows(old: "a\nb\n", new: "a\nb\nc\n")
      let scrollView = makeScrollView(rows: rows)
      let textView = scrollView.diffTextView
      // TextKit may measure the text taller than its rows.
      textView.setFrameSize(
        CGSize(width: 400, height: scrollView.contentFittingSize.height + 5))

      let last = try #require(textView.rowFillRect(at: rows.count - 1))
      #expect(rows.last?.kind == .added)
      #expect(last.maxY == textView.bounds.maxY)
      #expect(textView.rowFillRect(at: 0)?.minY == textView.bounds.minY)
      #expect(textView.rowFillRect(at: 1) == textView.rowRect(at: 1))
    }

    @Test("A file's hunks scroll sideways together and share the widest hunk's width")
    func hunksOfAFileScrollTogether() {
      let sync = DiffScrollSync()
      let short = NativeDiffScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
      let wide = NativeDiffScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
      for (view, text) in [(short, "let a = 1"), (wide, "let b = \"" + String(repeating: "x", count: 200) + "\"")] {
        view.maximumHeight = nil
        view.scrollSync = sync
        view.setContent(
          rows: LineDiff.rows(old: nil, new: text), highlights: [:], theme: .system,
          revision: UUID().uuidString)
      }
      _ = short.fitContent(toViewportWidth: 200)
      _ = wide.fitContent(toViewportWidth: 200)

      // The short hunk can travel as far as the wide one.
      #expect(short.diffTextView.frame.width == wide.diffTextView.frame.width)

      wide.contentView.scroll(to: NSPoint(x: 120, y: 0))
      wide.reflectScrolledClipView(wide.contentView)
      #expect(short.contentView.bounds.minX == 120)
    }

    @Test("Horizontal scrolling only activates for overflow")
    func enablesScrollingOnlyForOverflow() {
      let rows = LineDiff.rows(
        old: nil,
        new: "let value = \"This line is intentionally wider than the narrow viewport.\""
      )
      let scrollView = makeScrollView(rows: rows)
      let natural = scrollView.contentFittingSize

      let wide = scrollView.fitContent(toViewportWidth: natural.width + 100)
      #expect(!scrollView.hasHorizontalScroller)
      #expect(wide.height == natural.height)

      let narrow = scrollView.fitContent(toViewportWidth: 100)
      #expect(scrollView.hasHorizontalScroller)
      #expect(narrow.height == natural.height)
    }

    @Test("Row fills expand through the trailing viewport edge")
    func rowFillsUseFullViewportWidth() {
      let rows = LineDiff.rows(old: nil, new: "let value = 1")
      let scrollView = makeScrollView(rows: rows)
      let viewportWidth = scrollView.contentFittingSize.width + 200

      _ = scrollView.fitContent(toViewportWidth: viewportWidth)

      #expect(scrollView.diffTextView.frame.width == viewportWidth)
      #expect(scrollView.diffTextView.rowRect(at: 0)?.width == viewportWidth)
    }

    @Test("Thousands of lines do not multiply native text views")
    func largeDiffStillUsesOneTextView() {
      let source = (0..<5_000).map { "let value\($0) = \($0)" }.joined(separator: "\n")
      let rows = LineDiff.rows(old: nil, new: source)
      let scrollView = makeScrollView(rows: rows)

      #expect(rows.count == 5_000)
      #expect(countTextViews(in: scrollView) == 1)
      #expect(scrollView.contentFittingSize.height > DiffViewportMetrics.maximumHeight)
      #expect(
        scrollView.fitContent(toViewportWidth: 500).height
          == DiffViewportMetrics.maximumHeight
      )
      #expect(scrollView.hasVerticalScroller)
      #expect(scrollView.diffTextView.frame.height == scrollView.contentFittingSize.height)
    }

    @Test("An unbounded diff grows to full height and leaves vertical scrolling to its container")
    func unboundedDiffGrowsToFullHeight() {
      let source = (0..<1_000).map { "let value\($0) = \($0)" }.joined(separator: "\n")
      let rows = LineDiff.rows(old: nil, new: source)
      let scrollView = NativeDiffScrollView()
      scrollView.maximumHeight = nil
      scrollView.setContent(rows: rows, highlights: [:], theme: .system, revision: UUID().uuidString)
      let visible = scrollView.fitContent(toViewportWidth: 500)
      scrollView.frame = CGRect(origin: .zero, size: visible)
      scrollView.layoutSubtreeIfNeeded()

      #expect(visible.height == scrollView.contentFittingSize.height)
      #expect(visible.height > DiffViewportMetrics.maximumHeight)
      #expect(!scrollView.hasVerticalScroller)
      #expect(!scrollView.canConsumeVerticalDelta(1))
      #expect(!scrollView.canConsumeVerticalDelta(-1))
    }

    @Test("Vertical scrolling hands off to the transcript at both boundaries")
    func verticalScrollingChainsAtBoundaries() {
      let source = (0..<100).map { "let value\($0) = \($0)" }.joined(separator: "\n")
      let rows = LineDiff.rows(old: nil, new: source)
      let scrollView = makeScrollView(rows: rows)
      let visibleSize = scrollView.fitContent(toViewportWidth: 500)
      scrollView.frame = CGRect(origin: .zero, size: visibleSize)
      scrollView.layoutSubtreeIfNeeded()

      #expect(scrollView.hasVerticalScroller)
      #expect(!scrollView.canConsumeVerticalDelta(1))
      #expect(scrollView.canConsumeVerticalDelta(-1))

      let bottomY = scrollView.contentFittingSize.height - visibleSize.height
      scrollView.contentView.scroll(to: CGPoint(x: 0, y: bottomY))
      scrollView.reflectScrolledClipView(scrollView.contentView)

      #expect(scrollView.canConsumeVerticalDelta(1))
      #expect(!scrollView.canConsumeVerticalDelta(-1))
    }

    @Test("Highlighting updates the same surface without changing geometry")
    func highlightingPreservesSurfaceAndGeometry() {
      let rows = LineDiff.rows(old: nil, new: "let value = 1\nprint(value)")
      let scrollView = makeScrollView(rows: rows)
      let textView = scrollView.diffTextView
      let plainSize = scrollView.contentFittingSize
      var highlighted = AttributedString(rows[0].text)
      highlighted.foregroundColor = .blue

      scrollView.setContent(
        rows: rows,
        highlights: [rows[0].id: highlighted],
        theme: .system,
        revision: UUID().uuidString
      )

      #expect(scrollView.diffTextView === textView)
      #expect(scrollView.contentFittingSize == plainSize)
      #expect(textView.string == rows.map(\.text).joined(separator: "\n"))
    }

    private func makeScrollView(rows: [LineDiff.Row]) -> NativeDiffScrollView {
      let scrollView = NativeDiffScrollView()
      scrollView.setContent(
        rows: rows,
        highlights: [:],
        theme: .system,
        revision: UUID().uuidString
      )
      return scrollView
    }

    private func countTextViews(in view: NSView) -> Int {
      (view is NSTextView ? 1 : 0)
        + view.subviews.reduce(0) {
          $0 + countTextViews(in: $1)
        }
    }
  }
#endif

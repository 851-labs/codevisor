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

            #expect(countTextViews(in: scrollView) == 1)
            #expect(natural.height == CGFloat(rows.count) * NativeDiffMetrics(rows: rows).rowHeight)
            #expect(visible.height == natural.height)
            #expect(!scrollView.hasVerticalScroller)
            #expect(scrollView.diffTextView.frame.height == natural.height)
            #expect(scrollView.diffTextView.rowRect(at: 0)?.minY == 0)
            #expect(scrollView.diffTextView.rowRect(at: rows.count - 1)?.maxY == natural.height)
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

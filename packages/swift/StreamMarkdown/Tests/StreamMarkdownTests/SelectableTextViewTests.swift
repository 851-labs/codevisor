import AppKit
@testable import StreamMarkdown
import SwiftUI
import Testing

@MainActor
@Suite("Selectable TextKit text")
struct SelectableTextViewTests {
    @Test("Changing selection leaves display geometry unchanged")
    func selectionStableSizing() {
        let text = NSAttributedString(
            string: String(repeating: "A selectable line of transcript text. ", count: 30),
            attributes: [.font: NSFont.preferredFont(forTextStyle: .body)]
        )
        let view = SelectableTextKitView()
        view.setContent(text)

        let before = view.contentHeight(forWidth: 320)
        view.setSelectedRange(NSRange(location: 8, length: 90))
        let after = view.contentHeight(forWidth: 320)

        #expect(before == after)
        #expect(view.selectedRange() == NSRange(location: 8, length: 90))
    }

    @Test("Concrete width controls wrapping without mutating content")
    func widthControlsWrapping() {
        let text = NSAttributedString(
            string: String(repeating: "wrapped transcript text ", count: 20),
            attributes: [.font: NSFont.preferredFont(forTextStyle: .body)]
        )
        let view = SelectableTextKitView()
        view.setContent(text)

        let wide = view.contentHeight(forWidth: 500)
        let narrow = view.contentHeight(forWidth: 180)

        #expect(narrow > wide)
        #expect(text.string.hasPrefix("wrapped transcript"))
    }

    @Test("Measuring a proposed width does not resize the displayed text view")
    func measurementDoesNotResizeView() {
        let text = NSAttributedString(
            string: String(repeating: "side-effect-free measurement ", count: 20),
            attributes: [.font: NSFont.preferredFont(forTextStyle: .body)]
        )
        let view = SelectableTextKitView()
        view.setContent(text)
        view.setFrameSize(NSSize(width: 420, height: 80))
        let frameBeforeMeasurement = view.frame

        let measuredHeight = view.contentHeight(forWidth: 180)

        #expect(measuredHeight > 0)
        #expect(view.frame == frameBeforeMeasurement)
    }

    @Test("Content replacement invalidates the displayed layout measurement")
    func contentReplacementInvalidatesMeasurement() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.preferredFont(forTextStyle: .body)
        ]
        let view = SelectableTextKitView()
        view.setContent(NSAttributedString(string: "Short text", attributes: attributes))
        let shortHeight = view.contentHeight(forWidth: 180)

        view.setContent(
            NSAttributedString(
                string: String(repeating: "A much longer replacement. ", count: 30),
                attributes: attributes
            )
        )
        let longHeight = view.contentHeight(forWidth: 180)

        #expect(longHeight > shortHeight)
    }

    @Test("Markdown prose carries links, emphasis, and rounded code chips into TextKit")
    func markdownAttributes() {
        let rendered = MarkdownTextRunRenderer.attributedString(
            for: [
                .heading(level: 2, text: "Heading"),
                .paragraph(
                    "Use **strong** text, [the web](https://example.com), [a file](</tmp/cat.png>), and `code`."
                ),
            ],
            theme: .default,
            foregroundColor: .primary
        )
        let fullRange = NSRange(location: 0, length: rendered.length)
        var sawLink = false
        var sawServerFileLink = false
        var sawChip = false
        var sawBold = false
        rendered.enumerateAttributes(in: fullRange) { attributes, _, _ in
            sawLink = sawLink || attributes[.link] != nil
            sawServerFileLink =
                sawServerFileLink || attributes[.streamMarkdownServerFileLink] != nil
            sawChip = sawChip || attributes[.streamMarkdownRoundedBackground] != nil
            if let font = attributes[.font] as? NSFont {
                sawBold = sawBold || font.fontDescriptor.symbolicTraits.contains(.bold)
            }
        }

        #expect(rendered.string.contains("the web"))
        #expect(rendered.string.contains("a file"))
        #expect(rendered.string.contains("\u{202F}code\u{202F}"))
        #expect(sawLink)
        #expect(sawServerFileLink)
        #expect(sawChip)
        #expect(sawBold)
    }

    @Test("Nested prose lists flatten into one indented TextKit document")
    func flattenedNestedList() throws {
        let blocks = MarkdownParser().parse(
            """
            1. Outer item
               1. Nested item
               2. Another nested item
            2. Final item
            """
        )
        let firstBlock = try #require(blocks.first)
        let list = try #require(firstBlock.listValue)
        #expect(MarkdownTextRunRenderer.canRenderFlattenedList(list))

        let rendered = MarkdownTextRunRenderer.attributedString(
            for: blocks,
            theme: .default,
            foregroundColor: .primary
        )
        let string = rendered.string as NSString
        let outerRange = string.range(of: "1.\tOuter item")
        let nestedRange = string.range(of: "1.\tNested item")
        let finalRange = string.range(of: "2.\tFinal item")
        try #require(outerRange.location != NSNotFound)
        try #require(nestedRange.location != NSNotFound)
        try #require(finalRange.location != NSNotFound)
        let outerStyle = try #require(
            rendered.attribute(.paragraphStyle, at: outerRange.location, effectiveRange: nil)
                as? NSParagraphStyle
        )
        let nestedStyle = try #require(
            rendered.attribute(.paragraphStyle, at: nestedRange.location, effectiveRange: nil)
                as? NSParagraphStyle
        )

        #expect(outerStyle.firstLineHeadIndent == 0)
        #expect(outerStyle.headIndent == 22)
        #expect(nestedStyle.firstLineHeadIndent == 24)
        #expect(nestedStyle.headIndent == 46)
    }

    @Test("Mixed-content lists retain the recursive renderer fallback")
    func complexListFallback() {
        let list = MarkdownList(
            isOrdered: false,
            delimiter: "-",
            isTight: false,
            items: [
                MarkdownListItem(
                    blocks: [
                        .paragraph("Prose"),
                        .codeBlock(language: "swift", code: "let value = 1", isComplete: true),
                    ]
                )
            ]
        )

        #expect(!MarkdownTextRunRenderer.canRenderFlattenedList(list))
    }

    @Test("Nested quotes flatten into one decorated TextKit document")
    func flattenedNestedQuotes() throws {
        let block = MarkdownBlock.blockQuote([
            .paragraph("Level 1"),
            .blockQuote([.paragraph("Level 2")]),
        ])
        #expect(MarkdownTextRunRenderer.canRenderFlattenedText([block]))

        let rendered = MarkdownTextRunRenderer.attributedString(
            for: [block],
            theme: .default,
            foregroundColor: .primary
        )
        let string = rendered.string as NSString
        let level1Range = string.range(of: "Level 1")
        let level2Range = string.range(of: "Level 2")
        try #require(level1Range.location != NSNotFound)
        try #require(level2Range.location != NSNotFound)
        let level1Decoration = try #require(
            rendered.attribute(
                .streamMarkdownQuoteDecoration,
                at: level1Range.location,
                effectiveRange: nil
            ) as? TextKitQuoteDecoration
        )
        let level2Decoration = try #require(
            rendered.attribute(
                .streamMarkdownQuoteDecoration,
                at: level2Range.location,
                effectiveRange: nil
            ) as? TextKitQuoteDecoration
        )
        let level2Style = try #require(
            rendered.attribute(.paragraphStyle, at: level2Range.location, effectiveRange: nil)
                as? NSParagraphStyle
        )

        #expect(level1Decoration.barOffsets == [0])
        #expect(level2Decoration.barOffsets == [0, 11])
        #expect(level2Style.headIndent == 22)
    }

    @Test("Quotes inside lists preserve marker and quote indentation")
    func flattenedListQuote() throws {
        let list = MarkdownList(
            isOrdered: false,
            delimiter: "-",
            isTight: false,
            items: [
                MarkdownListItem(
                    blocks: [
                        .paragraph("Outer"),
                        .blockQuote([.paragraph("Quoted")]),
                    ]
                )
            ]
        )
        #expect(MarkdownTextRunRenderer.canRenderFlattenedList(list))

        let rendered = MarkdownTextRunRenderer.attributedString(
            for: [.list(list)],
            theme: .default,
            foregroundColor: .primary
        )
        let string = rendered.string as NSString
        let quotedRange = string.range(of: "Quoted")
        try #require(string.range(of: "•\tOuter").location != NSNotFound)
        try #require(quotedRange.location != NSNotFound)
        let decoration = try #require(
            rendered.attribute(
                .streamMarkdownQuoteDecoration,
                at: quotedRange.location,
                effectiveRange: nil
            ) as? TextKitQuoteDecoration
        )
        let style = try #require(
            rendered.attribute(.paragraphStyle, at: quotedRange.location, effectiveRange: nil)
                as? NSParagraphStyle
        )

        #expect(decoration.barOffsets == [22])
        #expect(style.headIndent == 33)
    }

    @Test("Content updates preserve and clamp selection")
    func contentUpdatesPreserveSelection() {
        let view = SelectableTextKitView()
        view.setContent(NSAttributedString(string: "0123456789"))
        view.setSelectedRange(NSRange(location: 4, length: 5))

        view.setContent(NSAttributedString(string: "012345"))

        #expect(view.selectedRange() == NSRange(location: 4, length: 2))
    }

    @Test("Hovering a link adds and removes an underline without changing its content")
    func linkHoverUnderline() {
        let text = NSMutableAttributedString(string: "Read the docs")
        let linkRange = NSRange(location: 5, length: 8)
        text.addAttributes(
            [
                .font: NSFont.preferredFont(forTextStyle: .body),
                .streamMarkdownServerFileLink: URL(string: "/tmp/docs")!,
            ],
            range: linkRange
        )
        let view = SelectableTextKitView()
        view.setContent(text)
        let height = view.contentHeight(forWidth: 320)
        view.setFrameSize(NSSize(width: 320, height: height))

        guard let layoutManager = view.layoutManager,
            let textContainer = view.textContainer
        else {
            Issue.record("Missing TextKit stack")
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let linkGlyphs = layoutManager.glyphRange(
            forCharacterRange: linkRange,
            actualCharacterRange: nil
        )
        let linkRect = layoutManager.boundingRect(forGlyphRange: linkGlyphs, in: textContainer)
        let hoverPoint = NSPoint(
            x: linkRect.midX + view.textContainerOrigin.x,
            y: linkRect.midY + view.textContainerOrigin.y
        )

        view.updateLinkHover(at: hoverPoint)

        #expect(view.hoveredLinkRange == linkRange)
        #expect(
            layoutManager.temporaryAttribute(
                .underlineStyle,
                atCharacterIndex: linkRange.location,
                effectiveRange: nil
            ) as? Int == NSUnderlineStyle.single.rawValue
        )
        #expect(view.string == "Read the docs")

        view.updateLinkHover(at: nil)

        #expect(view.hoveredLinkRange == nil)
        #expect(
            layoutManager.temporaryAttribute(
                .underlineStyle,
                atCharacterIndex: linkRange.location,
                effectiveRange: nil
            ) == nil
        )
    }

    @Test("Host-owned links use the host link action")
    func hostOwnedLinkUsesHostAction() {
        let destination = URL(string: "/Users/example/workspace/cat.png")!
        let view = SelectableTextKitView()
        var clickedURL: URL?
        view.linkAction = MarkdownLinkAction { url in
            clickedURL = url
            return true
        }

        #expect(view.activateServerFileLink(destination))

        #expect(clickedURL == destination)
    }

    @Test("Selection clears for every transcript TextKit surface on focus loss")
    func sharedSelectionClearsOnResign() {
        let storage = NSTextStorage(string: "A transcript selection")
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let view = TranscriptSelectableTextView(frame: .zero, textContainer: container)
        view.setSelectedRange(NSRange(location: 2, length: 10))

        #expect(view.resignFirstResponder())

        #expect(view.selectedRange() == NSRange(location: 12, length: 0))
    }

    @Test("Dragging out and back repaints the entire traversed selection")
    func outAndBackSelectionRepaintRange() {
        var tracker = SelectionRepaintTracker()
        tracker.begin(with: NSRange(location: 5, length: 0))
        #expect(tracker.record(NSRange(location: 5, length: 40)).isEmpty)
        #expect(tracker.record(NSRange(location: 5, length: 90)).isEmpty)
        #expect(
            tracker.record(NSRange(location: 5, length: 25))
                == [NSRange(location: 30, length: 65)]
        )
        #expect(
            tracker.record(NSRange(location: 5, length: 0))
                == [NSRange(location: 5, length: 25)]
        )

        #expect(
            tracker.finish(current: NSRange(location: 5, length: 0))
                == NSRange(location: 5, length: 90)
        )
    }

    @Test("Live selection cleanup handles movement through both endpoints")
    func liveSelectionRemovedRanges() {
        var tracker = SelectionRepaintTracker()
        tracker.begin(with: NSRange(location: 20, length: 30))

        #expect(
            tracker.record(NSRange(location: 10, length: 30))
                == [NSRange(location: 40, length: 10)]
        )
        #expect(
            tracker.record(NSRange(location: 25, length: 10))
                == [
                    NSRange(location: 10, length: 15),
                    NSRange(location: 35, length: 5),
                ]
        )
    }

    @Test("Past the visual end of a mixed-direction line maps to its logical end")
    func mixedDirectionLineEndHitTesting() {
        let rendered = MarkdownTextRunRenderer.attributedString(
            for: [
                .paragraph("Accented text: café, résumé, naïve, coöperate, São Paulo, Zürich."),
                .paragraph(
                    "Languages: 日本語のテキスト、 한국어 텍스트, العربية हिन्दी पाठ, Ελληνικά, кириллица."
                ),
            ],
            theme: .default,
            foregroundColor: .primary
        )
        let view = SelectableTextKitView()
        view.setContent(rendered)
        let height = view.contentHeight(forWidth: 1_200)
        view.setFrameSize(NSSize(width: 1_200, height: height))
        view.layoutSubtreeIfNeeded()

        guard let layoutManager = view.layoutManager,
            let textContainer = view.textContainer
        else {
            Issue.record("Missing TextKit stack")
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let finalGlyph = max(0, layoutManager.numberOfGlyphs - 1)
        let finalLine = layoutManager.lineFragmentUsedRect(
            forGlyphAt: finalGlyph, effectiveRange: nil
        )
        let point = NSPoint(x: finalLine.maxX + 100, y: finalLine.midY)

        #expect(view.characterIndexForInsertion(at: point) == rendered.length)
        #expect(view.logicalBoundaryOutsideVisualLine(at: point, anchor: 0) == rendered.length)
    }

}

private extension MarkdownBlock {
    var listValue: MarkdownList? {
        guard case let .list(list) = self else { return nil }
        return list
    }
}

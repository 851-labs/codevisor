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
        let measurer = TextKitTextMeasurer()

        let wide = measurer.height(for: text, width: 500)
        let narrow = measurer.height(for: text, width: 180)

        #expect(narrow > wide)
        #expect(text.string.hasPrefix("wrapped transcript"))
    }

    @Test("Markdown prose carries links, emphasis, and rounded code chips into TextKit")
    func markdownAttributes() {
        let rendered = MarkdownTextRunRenderer.attributedString(
            for: [
                .heading(level: 2, text: "Heading"),
                .paragraph("Use **strong** text, [a link](https://example.com), and `code`."),
            ],
            theme: .default,
            foregroundColor: .primary
        )
        let fullRange = NSRange(location: 0, length: rendered.length)
        var sawLink = false
        var sawChip = false
        var sawBold = false
        rendered.enumerateAttributes(in: fullRange) { attributes, _, _ in
            sawLink = sawLink || attributes[.link] != nil
            sawChip = sawChip || attributes[.streamMarkdownRoundedBackground] != nil
            if let font = attributes[.font] as? NSFont {
                sawBold = sawBold || font.fontDescriptor.symbolicTraits.contains(.bold)
            }
        }

        #expect(rendered.string.contains("a link"))
        #expect(rendered.string.contains("\u{202F}code\u{202F}"))
        #expect(sawLink)
        #expect(sawChip)
        #expect(sawBold)
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
                .link: URL(string: "https://example.com/docs")!,
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

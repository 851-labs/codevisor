import AppKit
@testable import StreamMarkdown
import SwiftUI
import Testing

@MainActor
@Suite("Settled native Markdown")
struct SettledMarkdownViewTests {
    @Test("Settled prose stays on TextKit 2 and selection does not change height")
    func textKit2SelectionStableSizing() {
        let text = NSAttributedString(
            string: String(repeating: "Native transcript text wraps predictably. ", count: 30),
            attributes: [.font: NSFont.preferredFont(forTextStyle: .body)]
        )
        let view = MarkdownTextKit2View()
        view.setContent(text)

        let before = view.contentHeight(forWidth: 280)
        view.setSelectedRange(NSRange(location: 7, length: 60))
        let after = view.contentHeight(forWidth: 280)

        #expect(view.usesTextKit2)
        #expect(before > 1)
        #expect(before == after)
        #expect(view.selectedRange() == NSRange(location: 7, length: 60))
    }

    @Test("Width changes invalidate native prose layout")
    func widthControlsWrapping() {
        let view = SettledMarkdownView()
        view.setContent(
            blocks: [
                .paragraph(String(repeating: "A settled Markdown sentence. ", count: 30))
            ],
            theme: .default,
            streamID: "settled-prose",
            linkAction: nil
        )

        let wide = view.contentHeight(forWidth: 600)
        let narrow = view.contentHeight(forWidth: 220)

        #expect(narrow > wide)
    }

    @Test("Settled selection clears when focus leaves the surface")
    func selectionClearsOnResign() {
        let view = MarkdownTextKit2View()
        view.setContent(NSAttributedString(string: "A native transcript selection"))
        view.setSelectedRange(NSRange(location: 2, length: 12))

        #expect(view.resignFirstResponder())
        #expect(view.selectedRange() == NSRange(location: 14, length: 0))
        #expect(view.usesTextKit2)
    }

    @Test("TextKit 2 preserves the established TextKit 1 line metrics")
    func settledLineMetricParity() {
        let rendered = MarkdownTextRunRenderer.attributedString(
            for: [
                .heading(level: 2, text: "A stable heading"),
                .paragraph(
                    String(
                        repeating: "Streaming and settled text share the same geometry. ",
                        count: 12
                    )
                ),
                .bulletList(["First item", "Second item with `code`"]),
            ],
            theme: .default,
            foregroundColor: .primary
        )
        let established = SelectableTextKitView()
        established.setContent(rendered)
        let settled = MarkdownTextKit2View()
        settled.setContent(rendered)

        for width: CGFloat in [220, 420, 760] {
            let establishedHeight = established.contentHeight(forWidth: width)
            let settledHeight = settled.contentHeight(forWidth: width)
            let delta = abs(establishedHeight - settledHeight)
            #expect(delta <= 1)
        }
    }

    @Test("Complex blocks report exact non-placeholder heights")
    func complexBlockHeights() {
        let parser = MarkdownParser()
        let blocks = parser.parse(
            """
            ```swift
            let answer = 42
            print(answer)
            ```

            | Name | Value |
            | --- | ---: |
            | answer | 42 |
            """
        )
        let view = SettledMarkdownView()
        view.setContent(
            blocks: blocks,
            theme: .default,
            streamID: "settled-complex",
            linkAction: nil
        )

        let height = view.contentHeight(forWidth: 500)

        #expect(height > 80)
    }

    @Test("Native code blocks preserve the established visible height")
    func codeBlockHeightParity() {
        let code = "let answer = 42\nprint(answer)"
        let established = NSHostingView(
            rootView: CodeBlockView(
                id: "established-code",
                language: "swift",
                code: code,
                isComplete: true
            )
            .markdownTheme(.default)
            .frame(width: 500)
        )
        let native = NativeMarkdownCodeBlockView(
            id: "native-code",
            language: "swift",
            code: code,
            theme: .default
        )

        let delta = abs(
            established.fittingSize.height
                - native.contentHeight(forWidth: 500)
        )

        #expect(delta <= 1)
    }

    @Test("Native tables preserve the established visible height")
    func tableHeightParity() {
        let parser = MarkdownParser()
        let headers = [parser.parseInline("Name"), parser.parseInline("Value")]
        let rows = [
            [parser.parseInline("answer"), parser.parseInline("42")],
            [parser.parseInline("language"), parser.parseInline("Swift")],
        ]
        let established = NSHostingView(
            rootView: MarkdownTableView(
                headers: headers,
                alignments: [.leading, .trailing],
                rows: rows
            )
            .markdownTheme(.default)
            .frame(width: 500)
        )
        let native = NativeMarkdownTableBlockView(
            headers: headers,
            alignments: [.leading, .trailing],
            rows: rows,
            theme: .default,
            linkAction: nil
        )

        let delta = abs(
            established.fittingSize.height
                - native.contentHeight(forWidth: 500)
        )

        #expect(delta <= 1)
    }
}

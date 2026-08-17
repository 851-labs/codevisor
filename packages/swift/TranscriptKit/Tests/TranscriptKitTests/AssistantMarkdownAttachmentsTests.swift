import Testing
@testable import TranscriptKit

@Suite("Assistant Markdown attachments")
struct AssistantMarkdownAttachmentsTests {
    private let recording = Attachment(
        fileId: "file-1",
        name: "fixed.mov",
        mimeType: "video/quicktime",
        sizeBytes: 42,
        kind: .file
    )

    @Test("Canonical links become attachment segments and ordinary links stay Markdown")
    func segments() {
        let report = Attachment(
            fileId: "file-2",
            name: "report.pdf",
            mimeType: "application/pdf",
            sizeBytes: 21,
            kind: .file
        )
        let result = assistantMarkdownSegments(
            "Done. [Recording](https://attachments.codevisor.invalid/file-1) [docs](https://example.com)",
            attachments: [recording, report]
        )
        #expect(
            result == [
                .markdown("Done. "),
                .file(PreviewFile(attachment: recording), label: "Recording"),
                .markdown(" [docs](https://example.com)"),
                .file(PreviewFile(attachment: report), label: "report.pdf"),
            ])
    }

    @Test("Local links stay Markdown while local images become previews")
    func localFiles() {
        let absolute = PreviewFile(serverPath: "/tmp/screen shot.png")
        let result = assistantMarkdownSegments(
            "Made [Report](./output/report.pdf) and ![Screenshot](</tmp/screen shot.png>). [Web](https://example.com).",
            attachments: []
        )
        #expect(
            result == [
                .markdown("Made [Report](./output/report.pdf) and "),
                .file(absolute, label: "Screenshot"),
                .markdown(". [Web](https://example.com)."),
            ])
    }

    @Test("Streaming leaves local image syntax in Markdown until the turn completes")
    func streamingLocalFiles() {
        let markdown = "Made ![Report](./output/report.pdf)"
        #expect(
            assistantMarkdownSegments(
                markdown,
                attachments: [],
                includeServerPaths: false
            ) == [.markdown(markdown)])
    }

    @Test("Extensionless Markdown destinations remain links")
    func extensionlessFiles() {
        let markdown = "Open [the readme](README)."
        #expect(
            assistantMarkdownSegments(
                markdown,
                attachments: []
            ) == [.markdown(markdown)])
    }

    @Test("Local link targets are distinguished from web links and anchors")
    func localLinkTargets() {
        #expect(markdownLocalFilePath("README") == "README")
        #expect(markdownLocalFilePath("../output/report.pdf") == "../output/report.pdf")
        #expect(markdownLocalFilePath("file:///tmp/report.pdf") == "file:///tmp/report.pdf")
        #expect(markdownLocalFilePath("https://example.com/report.pdf") == nil)
        #expect(markdownLocalFilePath("//example.com/report.pdf") == nil)
        #expect(markdownLocalFilePath("#results") == nil)
    }

    @Test("Links inside fenced code blocks remain literal Markdown")
    func fencedCode() {
        let markdown = #"""
            Examples:

            ```markdown
            ![Image](./cat.png)
            > ```
            [Still code](./cat.png)
            [Download](./cat.png)
            ```

            ~~~~
            [Another](../other.pdf)
            ~~~~
            """#
        #expect(assistantMarkdownSegments(markdown, attachments: []) == [.markdown(markdown)])
    }

    @Test("Unclosed and quoted fences protect their contents")
    func incompleteAndQuotedFences() {
        let quoted = #"""
            > ```
            > [Literal](./inside.txt)
            > ```

            ![Preview](./outside.txt)
            """#
        #expect(
            assistantMarkdownSegments(quoted, attachments: []) == [
                .markdown(
                    #"""
                    > ```
                    > [Literal](./inside.txt)
                    > ```
                    """# + "\n\n"),
                .file(PreviewFile(serverPath: "./outside.txt"), label: "Preview"),
            ])

        let unclosed = #"""
            ```text
            [Literal](./inside.txt)
            """#
        #expect(assistantMarkdownSegments(unclosed, attachments: []) == [.markdown(unclosed)])
    }

    @Test("Inline and indented code never becomes a file preview")
    func inlineAndIndentedCode() {
        let markdown = #"""
            Use `[Literal](./inline.txt)` or ``![Also literal](./inline.png)``.

                [Indented](./block.txt)

            Open ![Preview](./outside.txt).
            """#
        let beforePreview = #"""
            Use `[Literal](./inline.txt)` or ``![Also literal](./inline.png)``.

                [Indented](./block.txt)

            Open
            """# + " "
        #expect(
            assistantMarkdownSegments(markdown, attachments: []) == [
                .markdown(beforePreview),
                .file(PreviewFile(serverPath: "./outside.txt"), label: "Preview"),
                .markdown("."),
            ])
    }

    @Test("Escaped Markdown links remain text")
    func escapedLinks() {
        let markdown = #"Show \[Literal](./one.txt) and \![Image](./two.png)."#
        #expect(assistantMarkdownSegments(markdown, attachments: []) == [.markdown(markdown)])
    }

    @Test("Finalization replaces the streamed span and associates files")
    func finalization() {
        var turn = AssistantTurn(
            entries: [.text(id: "acp:answer-1", markdown: "[Recording](./fixed.mov)")],
            isGenerating: true,
            textPhases: ["acp:answer-1": .final]
        )
        TranscriptReducer.finalizeAssistant(
            markdown: "[Recording](https://attachments.codevisor.invalid/file-1)",
            messageId: "answer-1",
            attachments: [recording],
            to: &turn
        )
        #expect(
            turn.finalText
                == .text(
                    id: "acp:answer-1",
                    markdown: "[Recording](https://attachments.codevisor.invalid/file-1)"
                ))
        #expect(turn.attachments == [recording])
    }
}

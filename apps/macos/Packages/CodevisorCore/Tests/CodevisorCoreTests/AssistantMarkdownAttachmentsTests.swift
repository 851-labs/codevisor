import Testing
@testable import CodevisorCore

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
        #expect(result == [
            .markdown("Done. "),
            .file(PreviewFile(attachment: recording), label: "Recording"),
            .markdown(" [docs](https://example.com)"),
            .file(PreviewFile(attachment: report), label: "report.pdf")
        ])
    }

    @Test("Local file links become live server-file segments")
    func localFiles() {
        let relative = PreviewFile(serverPath: "./output/report.pdf")
        let absolute = PreviewFile(serverPath: "/tmp/screen shot.png")
        let result = assistantMarkdownSegments(
            "Made [Report](./output/report.pdf) and ![Screenshot](</tmp/screen shot.png>). [Web](https://example.com).",
            attachments: []
        )
        #expect(result == [
            .markdown("Made "),
            .file(relative, label: "Report"),
            .markdown(" and "),
            .file(absolute, label: "Screenshot"),
            .markdown(". [Web](https://example.com).")
        ])
    }

    @Test("Streaming leaves live file paths in Markdown until the turn completes")
    func streamingLocalFiles() {
        let markdown = "Made [Report](./output/report.pdf)"
        #expect(assistantMarkdownSegments(
            markdown,
            attachments: [],
            includeServerPaths: false
        ) == [.markdown(markdown)])
    }

    @Test("Extensionless Markdown destinations are local files")
    func extensionlessFiles() {
        let readme = PreviewFile(serverPath: "README")
        #expect(assistantMarkdownSegments(
            "Open [the readme](README).",
            attachments: []
        ) == [
            .markdown("Open "),
            .file(readme, label: "the readme"),
            .markdown(".")
        ])
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
        #expect(turn.finalText == .text(
            id: "acp:answer-1",
            markdown: "[Recording](https://attachments.codevisor.invalid/file-1)"
        ))
        #expect(turn.attachments == [recording])
    }
}

import Testing
@testable import TranscriptKit

@Suite("Assistant Markdown attachments")
struct AssistantMarkdownAttachmentsTests {
  @Test("Preserved View links stay clickable without adding a duplicate preview")
  func namedAttachmentLink() {
    let target = "https://attachments.codevisor.invalid/file-1?name=screen%20recording.mp4"
    let markdown = "[View recording](\(target))"
    #expect(assistantMarkdownSegments(markdown, attachments: [recording]) == [.markdown(markdown)])
    let file = markdownAttachmentFile(target)
    #expect(file?.source == .attachment(fileId: "file-1"))
    #expect(file?.name == "screen recording.mp4")
    #expect(file?.mimeType == "video/mp4")
    #expect(markdownAttachmentFile("https://example.com/file-1?name=recording.mp4") == nil)
  }
  private let recording = Attachment(
    fileId: "file-1",
    name: "fixed.mov",
    mimeType: "video/quicktime",
    sizeBytes: 42,
    kind: .file
  )
  private let outside = Attachment(
    fileId: "outside",
    name: "outside.txt",
    mimeType: "text/plain",
    sizeBytes: 7,
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

  @Test("A file listed twice on a message shows one preview")
  func duplicateAttachments() {
    let result = assistantMarkdownSegments(
      "See [Recording](https://attachments.codevisor.invalid/file-1)",
      attachments: [recording, recording]
    )
    #expect(
      result == [
        .markdown("See "),
        .file(PreviewFile(attachment: recording), label: "Recording"),
      ])
  }

  @Test("Local links and images stay Markdown; only the chat's own files become previews")
  func localFiles() {
    let markdown =
      "Made [Report](./output/report.pdf) and ![Screenshot](</tmp/screen shot.png>). [Web](https://example.com)."
    #expect(assistantMarkdownSegments(markdown, attachments: []) == [.markdown(markdown)])
  }

  @Test("While the turn streams, local images hold a pending card until the chat's copy arrives")
  func pendingLocalImages() {
    let markdown = "Made ![Screenshot](</tmp/screen shot.png>) and [Report](./output/report.pdf)."
    let pending = PreviewFile(pendingCapture: "/tmp/screen shot.png")
    #expect(
      assistantMarkdownSegments(markdown, attachments: [], localImagesPendingCapture: true) == [
        .markdown("Made "),
        .file(pending, label: "Screenshot"),
        .markdown(" and [Report](./output/report.pdf)."),
      ])
    #expect(pending.isPendingCapture)
    #expect(pending.kind == .image)
    #expect(pending.name == "screen shot.png")
  }

  @Test("Streaming defers unreferenced terminal attachments")
  func streamingUnreferencedAttachments() {
    let markdown = "The response is still growing"
    #expect(
      assistantMarkdownSegments(
        markdown,
        attachments: [recording],
        includeUnreferencedAttachments: false
      ) == [.markdown(markdown)])
    #expect(
      assistantMarkdownSegments(
        markdown,
        attachments: [recording],
        includeUnreferencedAttachments: true
      ) == [
        .markdown(markdown),
        .file(PreviewFile(attachment: recording), label: recording.name),
      ])
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
      ![Image](https://attachments.codevisor.invalid/outside)
      > ```
      [Still code](https://attachments.codevisor.invalid/outside)
      [Download](https://attachments.codevisor.invalid/outside)
      ```

      ~~~~
      [Another](https://attachments.codevisor.invalid/outside)
      ~~~~
      """#
    #expect(
      assistantMarkdownSegments(markdown, attachments: [outside], includeUnreferencedAttachments: false)
        == [.markdown(markdown)])
  }

  @Test("Unclosed and quoted fences protect their contents")
  func incompleteAndQuotedFences() {
    let quoted = #"""
      > ```
      > [Literal](./inside.txt)
      > ```

      ![Preview](https://attachments.codevisor.invalid/outside)
      """#
    #expect(
      assistantMarkdownSegments(quoted, attachments: [outside]) == [
        .markdown(
          #"""
          > ```
          > [Literal](./inside.txt)
          > ```
          """# + "\n\n"),
        .file(PreviewFile(attachment: outside), label: "Preview"),
      ])

    let unclosed = #"""
      ```text
      [Literal](https://attachments.codevisor.invalid/outside)
      """#
    #expect(
      assistantMarkdownSegments(unclosed, attachments: [outside], includeUnreferencedAttachments: false)
        == [.markdown(unclosed)])
  }

  @Test("Inline and indented code never becomes a file preview")
  func inlineAndIndentedCode() {
    let markdown = #"""
      Use `[Literal](https://attachments.codevisor.invalid/outside)` or ``![Also literal](https://attachments.codevisor.invalid/outside)``.

          [Indented](https://attachments.codevisor.invalid/outside)

      Open ![Preview](https://attachments.codevisor.invalid/outside).
      """#
    let beforePreview = #"""
      Use `[Literal](https://attachments.codevisor.invalid/outside)` or ``![Also literal](https://attachments.codevisor.invalid/outside)``.

          [Indented](https://attachments.codevisor.invalid/outside)

      Open
      """# + " "
    #expect(
      assistantMarkdownSegments(markdown, attachments: [outside]) == [
        .markdown(beforePreview),
        .file(PreviewFile(attachment: outside), label: "Preview"),
        .markdown("."),
      ])
  }

  @Test("Escaped Markdown links remain text")
  func escapedLinks() {
    let target = "https://attachments.codevisor.invalid/outside"
    let markdown = #"Show \[Literal]("# + target + #") and \![Image]("# + target + ")."
    #expect(
      assistantMarkdownSegments(markdown, attachments: [outside], includeUnreferencedAttachments: false)
        == [.markdown(markdown)])
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

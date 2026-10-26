import Foundation
import MarkdownCore
import Testing
@testable import TranscriptKit

@Suite("Assistant table images")
struct AssistantMarkdownTableImagesTests {
  private let cat = TranscriptKit.Attachment(
    fileId: "cat", name: "cat.png", mimeType: "image/png", sizeBytes: 10, kind: .image)

  @Test("Image tables stay intact")
  func tableSegments() {
    let markdown = "| Sign in | Create account |\n| --- | --- |\n| ![Sign in](./sign-in.png) | ![](./create.png) |"
    #expect(assistantMarkdownSegments(markdown, attachments: []) == [.markdown(markdown)])
  }

  @Test("Header images, nested tables, Unicode, and CRLF preserve parser-owned boundaries")
  func tableBoundaries() {
    let markdown =
      "前文 🐈\r\n\r\n> | ![](./header.png) | Two |\r\n> | --- | --- |\r\n> | ![猫](./cat.png) | x |\r\n\r\n![Outside](https://attachments.codevisor.invalid/cat)"
    let before = String(markdown.prefix(upTo: markdown.range(of: "![Outside]")!.lowerBound))
    #expect(
      assistantMarkdownSegments(markdown, attachments: [cat]) == [
        .markdown(before), .file(PreviewFile(attachment: cat), label: "Outside"),
      ])
    let parsed = MarkdownParser().parseWithTableRanges(markdown)
    #expect(parsed.tableRanges.count == 1)
    let table = (markdown as NSString).substring(with: parsed.tableRanges[0])
    #expect(table.contains("![](./header.png)"))
    #expect(table.contains("![猫](./cat.png)"))
    #expect(!table.contains("Outside"))
  }

  @Test("Attached table images do not also appear below the table", arguments: [false, true])
  func referencedAttachments(referenceStyle: Bool) {
    let attachment = TranscriptKit.Attachment(
      fileId: "image-1", name: "shot.png", mimeType: "image/png", sizeBytes: 10, kind: .image)
    let url = "https://attachments.codevisor.invalid/image-1"
    let embed = referenceStyle ? "![Shot][shot]" : "![](\(url))"
    let markdown = "| Preview |\n| --- |\n| \(embed) |" + (referenceStyle ? "\n\n[shot]: \(url)" : "")
    #expect(assistantMarkdownSegments(markdown, attachments: [attachment]) == [.markdown(markdown)])
  }

  @Test("Only real tables protect embeds; inline pipes still permit standalone previews")
  func inlinePipes() {
    let markdown = "Before | ![Shot](https://attachments.codevisor.invalid/cat) | after"
    #expect(
      assistantMarkdownSegments(markdown, attachments: [cat]) == [
        .markdown("Before | "), .file(PreviewFile(attachment: cat), label: "Shot"), .markdown(" | after"),
      ])
  }

  @Test("Fenced table examples stay literal and escaped pipes stay within cells")
  func codeAndEscapes() {
    let markdown =
      "```markdown\n| ![](./code.png) |\n| --- |\n```\n\n| Preview |\n| --- |\n| label \\| ![](./image.png) |"
    #expect(assistantMarkdownSegments(markdown, attachments: []) == [.markdown(markdown)])
    #expect(MarkdownParser().parseWithTableRanges(markdown).tableRanges.count == 1)
  }

  @Test("Empty tables and images in list-contained tables retain all cells")
  func listTable() {
    let markdown = "- Example:\n\n  | | |\n  | --- | --- |\n  | ![](./one.png) | ![](./two.png) |"
    #expect(assistantMarkdownSegments(markdown, attachments: []) == [.markdown(markdown)])
    #expect(MarkdownParser().parseWithTableRanges(markdown).tableRanges.count == 1)
  }
}

import Foundation
import Testing
import TranscriptKit

@testable import CodevisorUI

struct TranscriptFilePreviewTests {
  @Test(arguments: [
    ("Sources/App.swift", true),
    ("NOTES.md", true),
    ("fix.diff", true),
    ("fix.patch", true),
    ("server.log", true),
    ("Makefile", true),
    ("src/index.ts", true),
    ("shot.png", false),
    ("report.pdf", false),
    ("clip.mov", false),
    ("bundle.zip", false),
  ])
  func choosesTextPreviewsByName(path: String, previews: Bool) {
    #expect(PreviewFile(serverPath: path).showsTextPreview == previews)
  }

  @Test("A short text file keeps every line and reports its count")
  func wholeFile() throws {
    let excerpt = try #require(FileTextExcerpt(data: Data("one\r\ntwo\nthree\n".utf8)))
    #expect(excerpt.content == "one\ntwo\nthree")
    #expect(excerpt.lineCount == 3)
    #expect(!excerpt.isTruncated)
  }

  @Test("Binary content falls back to the file card")
  func binaryContent() {
    #expect(FileTextPreview(data: Data([0x89, 0x50, 0x00, 0x47])) == .binary)
    #expect(FileTextPreview(data: Data([0xFF, 0xFE, 0xFD])) == .binary)
  }

  @Test("A file longer than the line limit is cut at the limit")
  func lineLimit() throws {
    let lines = (1...(FileTextExcerpt.lineLimit + 5)).map { "line \($0)" }.joined(separator: "\n")
    let excerpt = try #require(FileTextExcerpt(data: Data(lines.utf8)))
    #expect(excerpt.isTruncated)
    #expect(excerpt.content.split(separator: "\n").count == FileTextExcerpt.lineLimit)
  }

  @Test("A read cut mid-line drops the partial line")
  func byteLimitAtLine() throws {
    let line = String(repeating: "x", count: 99) + "\n"
    let data = Data(String(repeating: line, count: FileTextExcerpt.byteLimit / 100 + 2).utf8)
    let excerpt = try #require(FileTextExcerpt(data: data.prefix(FileTextExcerpt.byteLimit + 1)))
    #expect(excerpt.isTruncated)
    #expect(excerpt.content.split(separator: "\n").allSatisfy { $0.count == 99 })
  }

  @Test("A read cut inside a character keeps the characters before it")
  func byteLimitInsideCharacter() throws {
    let data = Data(("a" + String(repeating: "é", count: FileTextExcerpt.byteLimit)).utf8)
    let excerpt = try #require(FileTextExcerpt(data: data.prefix(FileTextExcerpt.byteLimit + 1)))
    #expect(excerpt.isTruncated)
    #expect(excerpt.content.utf8.count == FileTextExcerpt.byteLimit - 1)
  }

  @Test("A patch file previews as a parsed diff, other text stays a code block")
  func patchPreview() {
    let patch = Data("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n".utf8)
    guard case let .diff(diff, isTruncated) = FileTextPreview(data: patch, isPatch: true) else {
      Issue.record("Expected a diff preview")
      return
    }
    #expect(diff.files.map(\.path) == ["x"])
    #expect(!isTruncated)
    #expect(FileTextPreview(data: patch) == .text(FileTextExcerpt(data: patch)!))
  }

  @Test("Bot messages lift the chat's own files out of the bubble, once each, and leave local paths as text")
  func botMessageContent() {
    let diff = Attachment(fileId: "d", name: "fix.diff", mimeType: "text/x-diff", sizeBytes: 10, kind: .file)
    let image = Attachment(fileId: "i", name: "shot.png", mimeType: "image/png", sizeBytes: 10, kind: .image)
    let message = TranscriptBotMessage(
      id: "m", sender: .bot,
      text: "Here:\n\n![](App.swift)\n\n![](https://attachments.codevisor.invalid/i)\n\nDone.",
      attachments: [diff, image])
    let content = TranscriptBotMessageContent(message)
    #expect(content.text == "Here:\n\n![](App.swift)\n\n\n\nDone.")
    #expect(content.files.map(\.name) == ["shot.png", "fix.diff"])
  }
}

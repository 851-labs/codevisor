import ACPKit
import Foundation
import Testing
@testable import TranscriptKit

@Suite("Native file reads")
struct ReadFileOutputTests {
  private func read(
    _ input: JSONValue?, output: JSONValue? = nil, content: [ToolCallContent]? = nil,
    locations: [ToolCallLocation]? = nil, status: ToolCallStatus = .completed
  ) -> ToolCall {
    ToolCall(
      toolCallId: "read", title: "Read", kind: .read, status: status, content: content,
      locations: locations, rawInput: input, rawOutput: output)
  }

  @Test("Claude Code's numbered lines read as the file")
  func claude() {
    let tabbed = read(
      ["file_path": "/repo/src/slugify.js"],
      output: "1\texport function slugify(text) {\n2\t  return text\n3\t}\n4\t")
    #expect(
      tabbed.readFileOutput
        == ReadFileOutput(
          path: "/repo/src/slugify.js", content: .text("export function slugify(text) {\n  return text\n}")))
    // Older Claude Code numbers with an arrow, and may append a reminder.
    let arrowed = read(
      ["file_path": "/repo/a.py", "offset": 10],
      output: "    10→def a():\n    11→    return 1\n\n<system-reminder>\nBe careful.\n</system-reminder>\n")
    #expect(arrowed.readFileOutput?.content == .text("def a():\n    return 1"))
    // Text blocks rather than one string.
    let blocks = read(["file_path": "/repo/b.txt"], output: .array([["type": "text", "text": "1\thello"]]))
    #expect(blocks.readFileOutput?.content == .text("hello"))
  }

  @Test("OpenCode's clean content wins over its wrapped output, which still unwraps")
  func openCode() {
    let wrapped: JSONValue = .object([
      "output":
        "<path>/repo/x.ts</path>\n<type>file</type>\n<content>\n1: const x = 1\n2: export { x }\n\n(End of file - total 2 lines)\n</content>"
    ])
    let withContent = read(
      ["filePath": "/repo/x.ts"], output: wrapped,
      content: [.content(.text("const x = 1\nexport { x }"))])
    #expect(withContent.readFileOutput?.content == .text("const x = 1\nexport { x }"))
    let outputOnly = read(nil, output: wrapped, locations: [ToolCallLocation(path: "/repo/x.ts")])
    #expect(
      outputOnly.readFileOutput == ReadFileOutput(path: "/repo/x.ts", content: .text("const x = 1\nexport { x }")))
  }

  @Test("Images, video, and PDFs show from their path, never their base64")
  func media() {
    let image = read(
      ["file_path": "/repo/shot.png"],
      output: .array([["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBOR"]]]))
    #expect(image.readFileOutput == ReadFileOutput(path: "/repo/shot.png", content: .media))
    #expect(read(["path": "/repo/demo.mov"], status: .inProgress).readFileOutput?.content == .media)
    #expect(read(["filePath": "/repo/spec.pdf"]).readFileOutput?.content == .media)
    // TypeScript isn't a transport stream, nor SVG an image to look at.
    #expect(read(["file_path": "/repo/a.ts"], output: "1\tx").readFileOutput?.content == .text("x"))
    #expect(read(["file_path": "/repo/i.svg"], output: "1\t<svg/>").readFileOutput?.content == .text("<svg/>"))
  }

  @Test("Unnamed, failed, unfinished, and non-read calls keep their usual body")
  func ignored() {
    #expect(read(nil, output: "1\tx").readFileOutput == nil)
    #expect(read(["file_path": "/repo/a.js"], output: "File does not exist.", status: .failed).readFileOutput == nil)
    #expect(read(["file_path": "/repo/a.js"], status: .inProgress).readFileOutput == nil)
    let shell = ToolCall(
      toolCallId: "sh", title: "Ran cat", kind: .execute, status: .completed,
      rawInput: ["file_path": "/repo/a.js"], rawOutput: "x")
    #expect(shell.readFileOutput == nil)
    // Text that merely starts with a number isn't line-numbered.
    #expect(read(["file_path": "/repo/n.txt"], output: "1\tone\ntwo").readFileOutput?.content == .text("1\tone\ntwo"))
  }

  @Test("Reversed content markers remain literal file text")
  func reversedContentMarkers() {
    let malformed = "</content><content>\nhello"
    #expect(
      read(["file_path": "/repo/n.txt"], output: .string(malformed)).readFileOutput
        == ReadFileOutput(path: "/repo/n.txt", content: .text(malformed)))
  }
}

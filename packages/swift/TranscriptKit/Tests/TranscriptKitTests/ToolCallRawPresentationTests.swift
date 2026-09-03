import ACPKit
import Foundation
import Testing
@testable import TranscriptKit

@Suite("ToolCall raw presentation")
struct ToolCallRawPresentationTests {
  @Test("Execute calls expose only output")
  func executeDetails() {
    let call = ToolCall(
      toolCallId: "run-1",
      title: "Ran printf",
      kind: .execute,
      rawInput: ["timeout": 30, "command": "printf 'one\\ntwo'"],
      rawOutput: "one\ntwo",
      exitCode: 0
    )

    let sections = call.rawDetailSections()
    #expect(call.hasPresentableDetails)
    #expect(sections.map(\.kind) == [.output])
    #expect(sections[0].text == "one\ntwo")
  }

  @Test("Typed content wins over raw fallback")
  func typedContentPrecedence() {
    let execute = ToolCall(
      toolCallId: "run-1",
      title: "Ran pwd",
      kind: .execute,
      content: [.content(.text("/tmp"))],
      rawInput: ["command": "pwd"],
      rawOutput: "duplicate"
    )
    #expect(execute.rawDetailSections().isEmpty)

    let edit = ToolCall(
      toolCallId: "edit-1",
      title: "Edited file",
      kind: .edit,
      content: [.diff(path: "a", oldText: "one", newText: "two")],
      rawInput: ["old_string": "one", "new_string": "two"],
      rawOutput: "Done"
    )
    #expect(edit.rawDetailSections().isEmpty)
  }

  @Test("Structured values use stable readable JSON")
  func structuredValues() {
    let call = ToolCall(
      toolCallId: "tool-1",
      title: "Tool",
      rawInput: ["z": 1, "a": "first"]
    )
    let text = call.rawDetailSections()[0].text
    #expect(text.firstIndex(of: "a")! < text.firstIndex(of: "z")!)
    #expect(text.contains(#""a" : "first""#))
  }

  @Test("Large results start with a bounded preview and retain the full text")
  func boundedPreview() {
    let output = String(repeating: "abcdefgh", count: 20)
    let call = ToolCall(toolCallId: "run-1", title: "Ran", rawOutput: .string(output))
    let section = call.rawDetailSections(previewCharacterLimit: 32)[0]

    #expect(section.isTruncated)
    #expect(section.preview.contains("truncated"))
    #expect(section.preview.hasPrefix("abcdefgh"))
    #expect(section.preview.hasSuffix("abcdefgh"))
    #expect(section.text == output)
  }

  @Test("Shell metadata without output does not make a call expandable")
  func exitCodeDetails() {
    let call = ToolCall(
      toolCallId: "run-1",
      title: "Ran",
      kind: .execute,
      rawInput: ["command": "false"],
      exitCode: 7
    )
    #expect(!call.hasPresentableDetails)
    #expect(call.rawDetailSections().isEmpty)
  }
}

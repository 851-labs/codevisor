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
      rawInput: ["h": 8, "c": 3, "a": "first/path", "f": 6, "b": 2, "g": 7, "e": 5, "d": 4]
    )
    #expect(
      call.rawDetailSections()[0].text == """
        {
          "a" : "first/path",
          "b" : 2,
          "c" : 3,
          "d" : 4,
          "e" : 5,
          "f" : 6,
          "g" : 7,
          "h" : 8
        }
        """)
  }

  @Test("Large results start with a bounded preview and retain the full text")
  func boundedPreview() {
    let output = String(repeating: "abcdefgh", count: 1_100)
    let call = ToolCall(toolCallId: "run-1", title: "Ran", rawOutput: .string(output))
    let section = call.rawDetailSections()[0]

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
      title: "Ran false",
      kind: .execute,
      rawInput: ["command": "false"],
      exitCode: 7
    )
    #expect(!call.hasPresentableDetails)
    #expect(call.rawDetailSections().isEmpty)
  }

  @Test("A script the title shows only the start of opens to the whole script")
  func scriptDetails() {
    let call = ToolCall(
      toolCallId: "run-2",
      title: "Ran cd app",
      kind: .execute,
      rawInput: ["command": "cd app\nswift test"]
    )
    #expect(call.hasPresentableDetails)
  }
}

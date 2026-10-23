import Testing

@testable import CodevisorUI

@Suite("Prompt queue preview text")
struct PromptQueuePreviewTextTests {
  @Test("Newlines, tabs and runs of spaces become single spaces")
  func collapsesWhitespace() {
    #expect(
      PromptQueuePreviewText.singleLine("  Fix the build\n\n\tthen  run\r\nthe tests \u{2028}@notes.md  ")
        == "Fix the build then run the tests @notes.md")
  }

  @Test("Text with no whitespace to collapse is unchanged")
  func leavesSingleLineText() {
    #expect(PromptQueuePreviewText.singleLine("Ship it") == "Ship it")
  }
}

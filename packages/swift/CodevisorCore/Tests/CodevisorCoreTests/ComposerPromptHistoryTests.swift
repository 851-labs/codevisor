import Testing
@testable import CodevisorCore

@Suite("ComposerPromptHistory")
struct ComposerPromptHistoryTests {
  @Test("Stepping back through prompts and forward again returns to an empty composer")
  func navigatesAndReturnsToEmpty() throws {
    var history = try #require(ComposerPromptHistory(entries: ["first", "second"]))

    #expect(history.previous() == "second")
    #expect(history.previous() == "first")
    #expect(history.previous() == nil)
    #expect(history.next() == "second")
    #expect(history.next() == "")
    #expect(history.next() == nil)
    #expect(ComposerPromptHistory(entries: []) == nil)
  }

  @Test("Entries are the chat's sent prompts, without blanks or repeats")
  func extractsEntriesFromConversation() {
    let pending = UserMessage(text: "in flight")
    let conversation: [ConversationItem] = [
      .user(UserMessage(text: "  fix the build\n")),
      .assistant(AssistantMessage(turn: AssistantTurn())),
      .user(UserMessage(text: "fix the build")),
      .user(UserMessage(text: "   ")),
      .user(UserMessage(text: "add tests")),
      .user(pending),
    ]

    #expect(
      ComposerPromptHistory.entries(in: conversation, pending: pending)
        == ["fix the build", "add tests", "in flight"]
    )
    #expect(
      ComposerPromptHistory.entries(in: [], pending: UserMessage(text: "first send"))
        == ["first send"]
    )
  }

  @Test("Recall starts only from an empty composer without attachments")
  func stepRequiresEmptyComposer() {
    let history = ComposerPromptHistory(entries: ["a", "b"])
    var cursor: ComposerPromptHistory?

    #expect(step(&cursor, history, text: "typing", older: true) == nil)
    #expect(cursor == nil)
    #expect(step(&cursor, history, text: "", attachments: true, older: true) == nil)
    #expect(cursor == nil)

    #expect(step(&cursor, history, text: "", older: true) == "b")
    #expect(step(&cursor, history, text: "b", older: true) == "a")
    #expect(step(&cursor, history, text: "a", attachments: true, older: false) == nil)
    #expect(cursor == nil)

    #expect(step(&cursor, history, text: "", older: true) == "b")
    #expect(step(&cursor, history, text: "b edited", older: true) == nil)
    #expect(cursor == nil)
  }

  @Test("A kept cursor walks back to empty and restarts after a new send")
  func stepRestartsStaleCursor() {
    var cursor: ComposerPromptHistory?
    let first = ComposerPromptHistory(entries: ["a"])
    #expect(step(&cursor, first, text: "", older: true) == "a")
    #expect(step(&cursor, first, text: "a", older: false) == "")
    #expect(step(&cursor, first, text: "", older: false) == nil)

    #expect(step(&cursor, first, text: "", older: true) == "a")
    let afterSend = ComposerPromptHistory(entries: ["a", "b"])
    #expect(step(&cursor, afterSend, text: "a", older: true) == nil)
    #expect(step(&cursor, afterSend, text: "", older: true) == "b")
  }

  private func step(
    _ cursor: inout ComposerPromptHistory?,
    _ fresh: ComposerPromptHistory?,
    text: String,
    attachments: Bool = false,
    older: Bool
  ) -> String? {
    ComposerPromptHistory.step(
      &cursor,
      fresh: fresh,
      composerText: text,
      hasAttachments: attachments,
      older: older
    )
  }
}

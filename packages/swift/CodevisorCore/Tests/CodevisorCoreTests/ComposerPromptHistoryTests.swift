import Testing
@testable import CodevisorCore

@Suite("ComposerPromptHistory")
struct ComposerPromptHistoryTests {
  @Test("Stepping back through prompts and forward again restores the draft")
  func navigatesAndRestoresDraft() throws {
    var history = try #require(ComposerPromptHistory(entries: ["first", "second"], draft: "half-typed"))

    #expect(history.previous() == "second")
    #expect(history.previous() == "first")
    #expect(history.previous() == nil)
    #expect(history.next() == "second")
    #expect(history.next() == "half-typed")
    #expect(history.next() == nil)
    #expect(ComposerPromptHistory(entries: [], draft: "") == nil)
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

  @Test("A kept cursor restarts after a new send and re-snapshots the draft")
  func stepRestartsStaleCursor() {
    var cursor: ComposerPromptHistory?
    let first = ComposerPromptHistory(entries: ["a"], draft: "draft 1")
    #expect(ComposerPromptHistory.step(&cursor, fresh: first, older: true) == "a")
    #expect(ComposerPromptHistory.step(&cursor, fresh: first, older: false) == "draft 1")

    // Back at the draft, the user typed more: ↑ then ↓ returns the new text.
    let edited = ComposerPromptHistory(entries: ["a"], draft: "draft 2")
    #expect(ComposerPromptHistory.step(&cursor, fresh: edited, older: true) == "a")
    #expect(ComposerPromptHistory.step(&cursor, fresh: edited, older: false) == "draft 2")

    // Mid-navigation, a new prompt was sent: ↑ starts over from the newest.
    #expect(ComposerPromptHistory.step(&cursor, fresh: edited, older: true) == "a")
    let afterSend = ComposerPromptHistory(entries: ["a", "b"], draft: "")
    #expect(ComposerPromptHistory.step(&cursor, fresh: afterSend, older: true) == "b")
  }
}

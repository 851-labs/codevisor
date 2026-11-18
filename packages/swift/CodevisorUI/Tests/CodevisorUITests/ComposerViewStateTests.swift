import CodevisorCore
import Foundation
import Testing

@testable import CodevisorUI

@Suite("A chat's composer state")
@MainActor
struct ComposerViewStateTests {
  private func chat() -> SessionController {
    SessionController(
      project: .fromFolder(URL(fileURLWithPath: "/tmp/composer-view-state-tests")),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
  }

  private func recordEdit(in history: ComposerUndoHistory) {
    history.manager.registerUndo(withTarget: history) { _ in }
  }

  @Test("Each chat has its own state")
  func stateBelongsToTheChat() {
    let first = chat()

    #expect(ComposerViewState.of(first) === ComposerViewState.of(first))
    #expect(ComposerViewState.of(first) !== ComposerViewState.of(chat()))
  }

  @Test("The caret is remembered for the draft it was placed in, and goes to the end of any other draft")
  func caretBelongsToItsDraft() {
    let state = ComposerViewState()

    #expect(state.selection(in: "fix the build") == NSRange(location: 13, length: 0))

    state.select(NSRange(location: 3, length: 0), in: "fix the build")

    #expect(state.selection(in: "fix the build") == NSRange(location: 3, length: 0))
    #expect(state.selection(in: "restored after a failed send") == NSRange(location: 28, length: 0))
  }

  @Test("An answer that finishes late does not unblock the question that replaced it")
  func lateAnswerLeavesTheNextQuestionAlone() {
    let state = ComposerViewState()
    state.setResolving(true, question: "first")
    state.setResolving(true, question: "second")

    state.setResolving(false, question: "first")

    #expect(state.isResolving("second"))
    #expect(!state.isResolving("first"))
    #expect(!state.isResolving(nil))
  }

  @Test("Undo history is kept per editor")
  func historyPerEditor() {
    let histories = ComposerUndoHistories()
    let editor = NSObject()

    #expect(histories.history(for: editor) === histories.history(for: editor))
    #expect(histories.history(for: editor) !== histories.history(for: NSObject()))
  }

  @Test("Coming back to the same draft keeps the undo history")
  func sameDraftKeepsHistory() {
    let history = ComposerUndoHistory()
    history.enter(showing: "draft")
    recordEdit(in: history)

    history.leave(showing: "draft edited")
    history.enter(showing: "draft edited")

    #expect(history.manager.canUndo)
  }

  @Test("A draft that changed while the chat was away drops the undo history")
  func changedDraftDropsHistory() {
    let history = ComposerUndoHistory()
    history.enter(showing: "draft")
    recordEdit(in: history)

    history.leave(showing: "draft")
    history.enter(showing: "draft edited elsewhere")

    #expect(!history.manager.canUndo)
  }
}

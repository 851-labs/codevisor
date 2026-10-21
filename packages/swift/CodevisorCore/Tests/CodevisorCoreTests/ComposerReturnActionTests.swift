import Testing
@testable import CodevisorCore

@Suite("ComposerReturnAction")
struct ComposerReturnActionTests {
  @Test("Return sends")
  func returnSends() {
    #expect(ComposerReturnAction(shift: false, option: false, command: false) == .send)
  }

  @Test("Shift+Return and Option+Return insert a line break")
  func shiftAndOptionInsertNewline() {
    #expect(ComposerReturnAction(shift: true, option: false, command: false) == .insertNewline)
    #expect(ComposerReturnAction(shift: false, option: true, command: false) == .insertNewline)
  }

  @Test("Cmd+Return queues")
  func commandQueues() {
    #expect(ComposerReturnAction(shift: false, option: false, command: true) == .queue)
  }

  @Test("A line-break modifier wins over Cmd")
  func newlineWinsOverCommand() {
    #expect(ComposerReturnAction(shift: true, option: false, command: true) == .insertNewline)
    #expect(ComposerReturnAction(shift: false, option: true, command: true) == .insertNewline)
  }
}

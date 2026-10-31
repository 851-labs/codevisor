import Foundation
import Testing
@testable import CodevisorCore

extension PaneGroupStateTests {
  @Test("Center initial state is a single selected chat pane")
  func centerInitial() {
    let state = PaneGroupState.centerInitial(sessionId: sessionId)
    #expect(state.panes.count == 1)
    #expect(state.panes[0].kind == .chat)
    #expect(state.selectedPaneId == state.panes[0].id)
  }

  @Test("Drafts and established chats close at the group level")
  func chatCloseRules() {
    var state = PaneGroupState.centerInitial(sessionId: sessionId)
    let anchor = state.panes[0]
    state.assignChatSession(paneId: anchor.id, sessionId: sessionId, name: "First")
    #expect(state.canClosePane(id: anchor.id))

    let draft = state.addChatPane()
    #expect(state.canClosePane(id: draft.id))
    #expect(state.closePane(id: draft.id) != nil)

    let second = state.addChatPane(sessionId: UUID(), name: "Second")
    #expect(state.closePane(id: second.id) != nil)
    #expect(state.selectedPaneId == anchor.id)
  }

  @Test("First send binds a draft pane to its session")
  func draftPromotion() {
    var state = PaneGroupState.centerInitial(sessionId: sessionId)
    let draft = state.addChatPane()
    #expect(draft.chatSessionId == nil)
    #expect(state.selectedPaneId == draft.id)

    let created = UUID()
    state.assignChatSession(paneId: draft.id, sessionId: created, name: "Build the parser")
    let bound = state.panes.first { $0.id == draft.id }
    #expect(bound?.chatSessionId == created)
    #expect(bound?.name == "Build the parser")
  }

  @Test("New Tab placeholders are real tabs: removable and group-locally closable")
  func newTabCloseRules() {
    var state = PaneGroupState()
    let placeholder = state.addNewTabPane()
    #expect(placeholder.kind == .newTab)
    #expect(state.selectedPaneId == placeholder.id)
    #expect(state.canClosePane(id: placeholder.id))
    var moved = state
    #expect(moved.removePane(id: placeholder.id) != nil)
    #expect(moved.panes.isEmpty)
    let terminal = state.addTerminalPane(sessionId: sessionId)
    #expect(state.closePane(id: placeholder.id) != nil)
    #expect(state.selectedPaneId == terminal.id)
  }

  @Test("Dead chat panes reset to a placeholder")
  func chatPaneHealing() {
    var dead = PaneGroupState.centerInitial(sessionId: sessionId)
    let deadId = dead.panes[0].id
    let placeholder = dead.resetChatPaneToPlaceholder(id: deadId)
    #expect(placeholder?.kind == .newTab)
    #expect(dead.panes.count == 1)
    #expect(dead.selectedPaneId == placeholder?.id)
    #expect(dead.resetChatPaneToPlaceholder(id: placeholder!.id) == nil)

    var terminal = PaneGroupState()
    let original = terminal.addTerminalPane(sessionId: sessionId)
    let reset = terminal.replacePaneWithNewTab(id: original.id)
    #expect(reset?.id == original.id)
    #expect(reset?.kind == .newTab)
    #expect(terminal.panes == [reset!])
  }

  @Test("Converting a New Tab placeholder replaces it in place")
  func newTabConversion() {
    var state = PaneGroupState()
    state.addTerminalPane(sessionId: sessionId)
    let placeholder = state.addNewTabPane()

    let terminal = state.convertNewTabPane(
      id: placeholder.id, to: .terminal, sessionId: sessionId
    )
    #expect(terminal?.kind == .terminal)
    #expect(terminal?.id == placeholder.id)
    #expect(terminal?.name == "Terminal")
    #expect(state.panes.map(\.id) == [state.panes[0].id, terminal?.id])
    #expect(state.selectedPaneId == terminal?.id)

    let second = state.addNewTabPane()
    let draft = state.convertNewTabPane(id: second.id, to: .chat, sessionId: sessionId)
    #expect(draft?.kind == .chat)
    #expect(draft?.id == second.id)
    #expect(draft?.chatSessionId == nil)

    let eager = state.addNewTabPane()
    let chatSession = UUID()
    let established = state.convertNewTabPane(
      id: eager.id, to: .chat, sessionId: sessionId,
      chatSessionId: chatSession, name: "New Chat"
    )
    #expect(established?.chatSessionId == chatSession)
    #expect(established?.id == eager.id)
    #expect(established?.name == "New Chat")

    #expect(state.convertNewTabPane(id: draft!.id, to: .terminal, sessionId: sessionId) == nil)
    let third = state.addNewTabPane()
    #expect(state.convertNewTabPane(id: third.id, to: .newTab, sessionId: sessionId) == nil)
  }
}

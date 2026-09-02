import Foundation
import Testing
@testable import CodevisorCore

extension PaneGroupStateTests {
    @Test("Center initial state is a visible, selected, immovable chat pane")
    func centerInitial() {
        let state = PaneGroupState.centerInitial(sessionId: sessionId)
        #expect(state.panes.count == 1)
        #expect(state.panes[0].kind == .chat)
        // Every pane moves between groups (tabs are tabs); whether the chat
        // may CLOSE is the owning model's workspace-wide policy.
        #expect(state.panes[0].isMovable)
        #expect(state.selectedPaneId == state.panes[0].id)
        #expect(state.isVisible)
    }

    @Test("Chat panes close at the group level (the anchor rule is the model's policy)")
    func chatPaneGroupLocalClose() {
        var state = PaneGroupState.centerInitial(sessionId: sessionId)
        let chatId = state.panes[0].id
        #expect(state.canClosePane(id: chatId))
        #expect(state.closePane(id: chatId) != nil)
        #expect(state.panes.isEmpty)
    }

    @Test("insertPane places a transferred pane at a clamped index and selects it")
    func insertPane() {
        var state = PaneGroupState.centerInitial(sessionId: sessionId)
        let transferred = PaneDescriptorState(
            id: UUID(), kind: .terminal, name: "Terminal 1", terminalKey: "k"
        )
        state.insertPane(transferred, at: 99)
        #expect(state.panes.map(\.name) == ["Chat", "Terminal 1"])
        #expect(state.selectedPaneId == transferred.id)

        let leading = PaneDescriptorState(
            id: UUID(), kind: .terminal, name: "Terminal 2", terminalKey: "k2"
        )
        state.insertPane(leading, at: -1)
        #expect(state.panes.first?.id == leading.id)

        // Re-inserting an already-present pane is a no-op.
        state.insertPane(transferred, at: 0)
        #expect(state.panes.count == 3)
    }

    @Test("Drafts and established chats close at the group level; chats never move")
    func chatCloseRules() {
        var state = PaneGroupState.centerInitial(sessionId: sessionId)
        let anchor = state.panes[0]
        // Bind the initial chat to its session (the backfill's shape).
        state.assignChatSession(paneId: anchor.id, sessionId: sessionId, name: "First")
        // Group-locally closable (close = archive); the workspace-wide
        // keep-one-chat anchor is the owning model's policy, not state's.
        // Moving is ungated for every kind.
        #expect(state.canClosePane(id: anchor.id))
        #expect(anchor.isMovable)

        // A draft closes freely.
        let draft = state.addChatPane()
        #expect(state.canClosePane(id: draft.id))
        #expect(state.closePane(id: draft.id) != nil)

        // Established chats close and selection moves on.
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

    @Test("New Tab placeholders are real tabs: movable, group-locally closable")
    func newTabCloseRules() {
        var state = PaneGroupState()
        let placeholder = state.addNewTabPane()
        #expect(placeholder.kind == .newTab)
        #expect(state.selectedPaneId == placeholder.id)
        // A real tab: drags between groups like the rest.
        #expect(placeholder.isMovable)
        // Group-locally closable — the cross-group rules (a lone
        // placeholder only closes when its group can dissolve) live in the
        // owning model's policies, which see the whole workspace.
        #expect(state.canClosePane(id: placeholder.id))
        // Extraction (a MOVE) removes without consulting close rules.
        var moved = state
        #expect(moved.removePane(id: placeholder.id) != nil)
        #expect(moved.panes.isEmpty)
        // Closing with company behaves like any tab: selection moves on.
        let terminal = state.addTerminalPane(sessionId: sessionId)
        #expect(state.closePane(id: placeholder.id) != nil)
        #expect(state.selectedPaneId == terminal.id)
    }

    @Test("Dead chat panes heal: unbind back to draft, or reset to a placeholder")
    func chatPaneHealing() {
        // Unbind: a failed first-send deleted the session; the pane keeps
        // its slot and composer as a draft.
        var state = PaneGroupState.centerInitial(sessionId: sessionId)
        let chatId = state.panes[0].id
        state.unbindChatPane(paneId: chatId)
        #expect(state.panes[0].chatSessionId == nil)
        #expect(state.panes[0].name == "New Chat")
        #expect(state.panes[0].id == chatId)

        // Reset: a vanished session's pane becomes a New Tab placeholder
        // in place, selection following.
        var dead = PaneGroupState.centerInitial(sessionId: sessionId)
        let deadId = dead.panes[0].id
        let placeholder = dead.resetChatPaneToPlaceholder(id: deadId)
        #expect(placeholder?.kind == .newTab)
        #expect(dead.panes.count == 1)
        #expect(dead.selectedPaneId == placeholder?.id)
        // Only chat panes reset.
        #expect(dead.resetChatPaneToPlaceholder(id: placeholder!.id) == nil)

        // The server's final-pane close transition works for every renderer
        // and preserves its stable shared identity.
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

        // Terminal conversion: same slot, next terminal name, selected.
        let terminal = state.convertNewTabPane(
            id: placeholder.id, to: .terminal, sessionId: sessionId
        )
        #expect(terminal?.kind == .terminal)
        #expect(terminal?.id == placeholder.id)
        #expect(terminal?.name == "Terminal 2")
        #expect(state.panes.map(\.id) == [state.panes[0].id, terminal?.id])
        #expect(state.selectedPaneId == terminal?.id)

        // Chat conversion without a session produces a DRAFT (binds on
        // first send)…
        let second = state.addNewTabPane()
        let draft = state.convertNewTabPane(id: second.id, to: .chat, sessionId: sessionId)
        #expect(draft?.kind == .chat)
        #expect(draft?.id == second.id)
        #expect(draft?.chatSessionId == nil)

        // …and with an eagerly created session, an ESTABLISHED chat.
        let eager = state.addNewTabPane()
        let chatSession = UUID()
        let established = state.convertNewTabPane(
            id: eager.id, to: .chat, sessionId: sessionId,
            chatSessionId: chatSession, name: "New Chat"
        )
        #expect(established?.chatSessionId == chatSession)
        #expect(established?.id == eager.id)
        #expect(established?.name == "New Chat")

        // Only placeholders convert; a placeholder can't "convert" to one.
        #expect(state.convertNewTabPane(id: draft!.id, to: .terminal, sessionId: sessionId) == nil)
        let third = state.addNewTabPane()
        #expect(state.convertNewTabPane(id: third.id, to: .newTab, sessionId: sessionId) == nil)
    }
}

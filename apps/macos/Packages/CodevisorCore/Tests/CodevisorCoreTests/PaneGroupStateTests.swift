import Foundation
import Testing
@testable import CodevisorCore

@Suite("PaneGroupState")
struct PaneGroupStateTests {
    private let sessionId = UUID()

    @Test("Defaults are hidden at the default height with no panes")
    func defaults() {
        let state = PaneGroupState()
        #expect(!state.isVisible)
        #expect(state.height == PaneGroupState.defaultHeight)
        #expect(state.panes.isEmpty)
        #expect(state.selectedPaneId == nil)
    }

    @Test("Toggle opens and focuses the terminal, then closes and focuses the composer")
    func toggle() {
        var state = PaneGroupState.initial(sessionId: sessionId)
        #expect(state.toggle() == .terminal)
        #expect(state.isVisible)
        #expect(state.toggle() == .composer)
        #expect(!state.isVisible)
    }

    @Test("Height is clamped to the allowed range")
    func clamping() {
        var state = PaneGroupState()
        state.setHeight(10_000)
        #expect(state.height == PaneGroupState.maxHeight)
        state.setHeight(0)
        #expect(state.height == PaneGroupState.minHeight)
        state.setHeight(300)
        #expect(state.height == 300)
    }

    @Test("Initializer clamps the provided height")
    func initClamps() {
        #expect(PaneGroupState(height: -5).height == PaneGroupState.minHeight)
        #expect(PaneGroupState(height: 5_000).height == PaneGroupState.maxHeight)
    }

    @Test("Initial state has one selected terminal pane keyed on the bare session UUID")
    func initialState() {
        let state = PaneGroupState.initial(sessionId: sessionId)
        #expect(state.panes.count == 1)
        #expect(state.panes[0].name == "Terminal 1")
        #expect(state.panes[0].kind == .terminal)
        // Migration: pane 1 must reattach to shells created before panes existed.
        #expect(state.panes[0].terminalKey == sessionId.uuidString)
        #expect(state.selectedPaneId == state.panes[0].id)
        #expect(!state.isVisible)
    }

    @Test("Adding a pane names it Terminal N, selects it, opens the group, and uses a synthetic key")
    func addPane() {
        var state = PaneGroupState.initial(sessionId: sessionId)
        let added = state.addTerminalPane(sessionId: sessionId)
        #expect(added.name == "Terminal 2")
        #expect(state.panes.count == 2)
        #expect(state.selectedPaneId == added.id)
        #expect(state.isVisible)
        #expect(added.terminalKey == "\(sessionId.uuidString):\(added.id.uuidString)")
    }

    @Test("Adding a terminal pane records the spawn context's cwd override")
    func addPaneInheritsCwd() {
        var state = PaneGroupState.initial(sessionId: sessionId)
        let inherited = state.addTerminalPane(
            sessionId: sessionId, cwdOverride: "/tmp/worktree"
        )
        #expect(inherited.cwdOverride == "/tmp/worktree")
        // Default stays nil: the anchor session's cwd resolution.
        #expect(state.addTerminalPane(sessionId: sessionId).cwdOverride == nil)
    }

    @Test("A New Tab placeholder stores the spawning context for its page's preselect")
    func newTabPaneInheritsCwd() {
        var state = PaneGroupState.centerInitial(sessionId: sessionId)
        let placeholder = state.addNewTabPane(inheritedCwd: "/tmp/worktree")
        #expect(placeholder.cwdOverride == "/tmp/worktree")
        #expect(placeholder.kind == .newTab)
        // Converting to a terminal uses the EXPLICIT pick, not the inherited hint.
        let converted = state.convertNewTabPane(
            id: placeholder.id, to: .terminal, sessionId: sessionId, cwd: "/tmp/other"
        )
        #expect(converted?.cwdOverride == "/tmp/other")
    }

    @Test("Naming is max numeric suffix + 1, including after close and re-add")
    func naming() {
        #expect(PaneGroupState.nextTerminalName(existing: []) == "Terminal 1")
        #expect(PaneGroupState.nextTerminalName(existing: ["Terminal 1"]) == "Terminal 2")
        #expect(PaneGroupState.nextTerminalName(existing: ["Terminal 1", "Terminal 3"]) == "Terminal 4")
        #expect(PaneGroupState.nextTerminalName(existing: ["Renamed", "Terminal 2"]) == "Terminal 3")

        var state = PaneGroupState.initial(sessionId: sessionId)
        let second = state.addTerminalPane(sessionId: sessionId)
        state.closePane(id: second.id)
        // After closing "Terminal 2" of [1, 2], the next add is "Terminal 2" again.
        #expect(state.addTerminalPane(sessionId: sessionId).name == "Terminal 2")
    }

    @Test("Closing the selected pane selects its right neighbor, else the new last pane")
    func closeSelectsNeighbor() {
        var state = PaneGroupState.initial(sessionId: sessionId)
        let second = state.addTerminalPane(sessionId: sessionId)
        let third = state.addTerminalPane(sessionId: sessionId)
        state.selectPane(id: second.id)
        state.closePane(id: second.id)
        #expect(state.selectedPaneId == third.id)
        // Closing the last pane in the list falls back to the left neighbor.
        state.closePane(id: third.id)
        #expect(state.selectedPaneId == state.panes[0].id)
    }

    @Test("Closing a non-selected pane keeps the selection")
    func closeKeepsSelection() {
        var state = PaneGroupState.initial(sessionId: sessionId)
        let first = state.panes[0]
        let second = state.addTerminalPane(sessionId: sessionId)
        state.closePane(id: first.id)
        #expect(state.selectedPaneId == second.id)
    }

    @Test("Closing the last remaining pane hides the group and clears selection")
    func closeLastHides() {
        var state = PaneGroupState.initial(sessionId: sessionId)
        state.selectPane(id: state.panes[0].id)
        #expect(state.isVisible)
        state.closePane(id: state.panes[0].id)
        #expect(state.panes.isEmpty)
        #expect(state.selectedPaneId == nil)
        #expect(!state.isVisible)
    }

    @Test("Selecting a pane while collapsed opens the group")
    func selectOpens() {
        var state = PaneGroupState.initial(sessionId: sessionId)
        #expect(!state.isVisible)
        state.selectPane(id: state.panes[0].id)
        #expect(state.isVisible)
        // Unknown ids are ignored.
        state.selectPane(id: UUID())
        #expect(state.selectedPaneId == state.panes[0].id)
    }

    @Test("Moving a pane reorders it around the target in both directions")
    func movePane() {
        var state = PaneGroupState.initial(sessionId: sessionId)
        let first = state.panes[0]
        let second = state.addTerminalPane(sessionId: sessionId)
        let third = state.addTerminalPane(sessionId: sessionId)

        state.movePane(id: first.id, onto: third.id)
        #expect(state.panes.map(\.id) == [second.id, third.id, first.id])

        state.movePane(id: first.id, onto: second.id)
        #expect(state.panes.map(\.id) == [first.id, second.id, third.id])

        // No-ops: same pane, unknown ids.
        state.movePane(id: first.id, onto: first.id)
        state.movePane(id: UUID(), onto: second.id)
        #expect(state.panes.map(\.id) == [first.id, second.id, third.id])
    }

    @Test("Agent terminal panes are keyed, deduped, and never steal selection or open the group")
    func agentTerminalPanes() {
        var state = PaneGroupState.initial(sessionId: sessionId)
        let selectedBefore = state.selectedPaneId
        let key = "\(sessionId.uuidString):bg:tool-1"

        let pane = state.ensureAgentTerminalPane(name: "npm run dev", terminalKey: key)
        #expect(pane.attachOnly)
        #expect(pane.name == "npm run dev")
        #expect(state.panes.count == 2)
        #expect(state.selectedPaneId == selectedBefore)
        #expect(state.isVisible == false)

        // Re-ensuring the same terminal key returns the existing pane.
        let again = state.ensureAgentTerminalPane(name: "renamed", terminalKey: key)
        #expect(again.id == pane.id)
        #expect(state.panes.count == 2)

        // With nothing selected (empty group), the agent pane becomes the
        // selection so the bar has a coherent state.
        var empty = PaneGroupState()
        let first = empty.ensureAgentTerminalPane(name: "dev", terminalKey: key)
        #expect(empty.selectedPaneId == first.id)
        #expect(empty.isVisible == false)
    }

    @Test("Descriptors persisted before attachOnly existed decode as user shells")
    func decodeLegacyDescriptor() throws {
        let legacy = Data("""
        {"id":"\(UUID().uuidString)","kind":"terminal","name":"Terminal 1","terminalKey":"abc"}
        """.utf8)
        let decoded = try JSONDecoder().decode(PaneDescriptorState.self, from: legacy)
        #expect(decoded.attachOnly == false)
        // Pre-owner-scoping agent tabs decode ownerless (any syncer adopts).
        #expect(decoded.ownerChatSessionId == nil)
    }

    @Test("New tab conversion to terminal carries a picked directory")
    func newTabConversionCwd() throws {
        var state = PaneGroupState.initial(sessionId: sessionId)
        let placeholder = state.addNewTabPane()
        let converted = state.convertNewTabPane(
            id: placeholder.id,
            to: .terminal,
            sessionId: sessionId,
            cwd: "/tmp/worktrees/rayleigh"
        )
        #expect(converted?.cwdOverride == "/tmp/worktrees/rayleigh")
        // And it survives persistence (terminals reopen where they were).
        let decoded = try JSONDecoder().decode(
            PaneGroupState.self, from: JSONEncoder().encode(state)
        )
        #expect(
            decoded.panes.first { $0.id == converted?.id }?.cwdOverride
                == "/tmp/worktrees/rayleigh"
        )
        // Panes persisted before directory picking decode with no override.
        let legacy = Data("""
        {"id":"\(UUID().uuidString)","kind":"terminal","name":"T","terminalKey":"k"}
        """.utf8)
        #expect(try JSONDecoder().decode(PaneDescriptorState.self, from: legacy).cwdOverride == nil)
    }

    @Test("Agent terminal panes carry their owning chat and round-trip it")
    func agentTerminalOwner() throws {
        var state = PaneGroupState.initial(sessionId: sessionId)
        let owner = UUID()
        let pane = state.ensureAgentTerminalPane(
            name: "bun run dev",
            terminalKey: "\(sessionId.uuidString):bg:tool-2",
            ownerChatSessionId: owner
        )
        #expect(pane.ownerChatSessionId == owner)
        let decoded = try JSONDecoder().decode(
            PaneGroupState.self, from: JSONEncoder().encode(state)
        )
        #expect(decoded.panes.first { $0.id == pane.id }?.ownerChatSessionId == owner)
    }

    @Test("Codable round-trip preserves panes, selection, visibility, and height")
    func codableRoundTrip() throws {
        var state = PaneGroupState.initial(sessionId: sessionId)
        state.addTerminalPane(sessionId: sessionId)
        state.setHeight(420)
        let decoded = try JSONDecoder().decode(
            PaneGroupState.self,
            from: JSONEncoder().encode(state)
        )
        #expect(decoded == state)
    }

    @Test("Decoding drops a selection that no longer matches a pane")
    func decodeRepairsSelection() throws {
        var state = PaneGroupState.initial(sessionId: sessionId)
        state.selectedPaneId = nil
        let decoded = try JSONDecoder().decode(
            PaneGroupState.self,
            from: JSONEncoder().encode(state)
        )
        #expect(decoded.selectedPaneId == state.panes[0].id)
    }

    @Test("Repository round-trips state per session")
    func repository() {
        let repo = DefaultPaneGroupRepository(store: InMemoryStore())
        let otherSession = UUID()
        #expect(repo.load(sessionId: sessionId, placement: .bottom) == nil)
        var state = PaneGroupState.initial(sessionId: sessionId)
        state.addTerminalPane(sessionId: sessionId)
        repo.save(state, sessionId: sessionId, placement: .bottom)
        repo.save(.initial(sessionId: otherSession), sessionId: otherSession, placement: .bottom)
        #expect(repo.load(sessionId: sessionId, placement: .bottom) == state)
        #expect(repo.load(sessionId: otherSession, placement: .bottom)?.panes.count == 1)
    }

    @Test("Repository stores the center group separately from the bottom panel")
    func repositoryPlacements() {
        let repo = DefaultPaneGroupRepository(store: InMemoryStore())
        let bottom = PaneGroupState.initial(sessionId: sessionId)
        let center = PaneGroupState.centerInitial(sessionId: sessionId)
        repo.save(bottom, sessionId: sessionId, placement: .bottom)
        #expect(repo.load(sessionId: sessionId, placement: .center) == nil)
        repo.save(center, sessionId: sessionId, placement: .center)
        #expect(repo.load(sessionId: sessionId, placement: .bottom) == bottom)
        #expect(repo.load(sessionId: sessionId, placement: .center) == center)
    }

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
        #expect(terminal?.name == "Terminal 2")
        #expect(state.panes.map(\.id) == [state.panes[0].id, terminal?.id])
        #expect(state.selectedPaneId == terminal?.id)

        // Chat conversion without a session produces a DRAFT (binds on
        // first send)…
        let second = state.addNewTabPane()
        let draft = state.convertNewTabPane(id: second.id, to: .chat, sessionId: sessionId)
        #expect(draft?.kind == .chat)
        #expect(draft?.chatSessionId == nil)

        // …and with an eagerly created session, an ESTABLISHED chat.
        let eager = state.addNewTabPane()
        let chatSession = UUID()
        let established = state.convertNewTabPane(
            id: eager.id, to: .chat, sessionId: sessionId,
            chatSessionId: chatSession, name: "New Chat"
        )
        #expect(established?.chatSessionId == chatSession)
        #expect(established?.name == "New Chat")

        // Only placeholders convert; a placeholder can't "convert" to one.
        #expect(state.convertNewTabPane(id: draft!.id, to: .terminal, sessionId: sessionId) == nil)
        let third = state.addNewTabPane()
        #expect(state.convertNewTabPane(id: third.id, to: .newTab, sessionId: sessionId) == nil)
    }
}

import Foundation
import Testing
@testable import CodevisorCore

@Suite("Workspace focused chat")
struct WorkspaceReadAcknowledgementTests {
    @Test("Only the selected chat pane of the active leaf in the selected tab is focused")
    func focusedChatResolution() {
        let firstChatId = UUID()
        let secondChatId = UUID()
        let backgroundChatId = UUID()
        let firstLeafId = UUID()
        let secondLeafId = UUID()
        let backgroundLeafId = UUID()
        let selectedTab = WorkspaceTab(
            root: .split(
                orientation: .horizontal,
                children: [
                    SplitChild(
                        fraction: 0.5,
                        node: .leaf(chatState(firstChatId), id: firstLeafId)
                    ),
                    SplitChild(
                        fraction: 0.5,
                        node: .leaf(chatState(secondChatId), id: secondLeafId)
                    ),
                ]
            ),
            activeLeafId: firstLeafId
        )
        let backgroundTab = WorkspaceTab(
            root: .leaf(chatState(backgroundChatId), id: backgroundLeafId)
        )
        let workspace = Workspace(
            name: "Attention",
            rootDirectory: "/tmp/attention",
            serverId: "local",
            projectId: UUID(),
            centerTabs: [selectedTab, backgroundTab],
            selectedCenterTabId: selectedTab.id,
            bottomGroup: PaneGroupState()
        )

        // Nil active leaf falls back to the selected tab's persisted one.
        #expect(workspace.focusedChatId(activeLeafId: nil) == firstChatId)
        #expect(workspace.focusedChatId(activeLeafId: firstLeafId) == firstChatId)
        // Activating the other split focuses its chat; the first split's chat
        // stays mounted but is no longer the focused one.
        #expect(workspace.focusedChatId(activeLeafId: secondLeafId) == secondChatId)
        // A chat in a non-selected top tab can never be focused, even when
        // its own leaf id is passed (stale leaf falls back to the selected
        // tab's active leaf).
        #expect(workspace.focusedChatId(activeLeafId: backgroundLeafId) == firstChatId)
    }

    @Test("A non-chat selected pane focuses no chat")
    func nonChatPaneFocusesNothing() {
        let terminalPane = PaneDescriptorState(
            id: UUID(),
            kind: .terminal,
            name: "Terminal",
            terminalKey: "term-1",
            chatSessionId: nil
        )
        let leafId = UUID()
        let tab = WorkspaceTab(
            root: .leaf(
                PaneGroupState(
                    panes: [terminalPane],
                    selectedPaneId: terminalPane.id,
                    isVisible: true
                ),
                id: leafId
            ),
            activeLeafId: leafId
        )
        let workspace = Workspace(
            name: "Terminals",
            rootDirectory: "/tmp/terminals",
            serverId: "local",
            projectId: UUID(),
            centerTabs: [tab],
            selectedCenterTabId: tab.id,
            bottomGroup: PaneGroupState()
        )
        #expect(workspace.focusedChatId(activeLeafId: leafId) == nil)
    }

    private func chatState(_ chatId: UUID) -> PaneGroupState {
        let pane = PaneDescriptorState(
            id: UUID(),
            kind: .chat,
            name: "Chat",
            terminalKey: chatId.uuidString,
            chatSessionId: chatId
        )
        return PaneGroupState(
            panes: [pane],
            selectedPaneId: pane.id,
            isVisible: true
        )
    }
}

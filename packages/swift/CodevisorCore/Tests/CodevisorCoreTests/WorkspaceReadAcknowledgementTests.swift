import Foundation
import Testing
@testable import CodevisorCore

@Suite("Workspace read acknowledgements")
struct WorkspaceReadAcknowledgementTests {
    @Test("Only the routed chat in the active selected leaf may acknowledge reads")
    func readAcknowledgementOwner() {
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

        #expect(
            workspace.isReadAcknowledgementEligible(
                forChat: firstChatId,
                inLeaf: firstLeafId,
                routedSessionId: firstChatId,
                activeLeafId: nil
            ))
        #expect(
            !workspace.isReadAcknowledgementEligible(
                forChat: secondChatId,
                inLeaf: secondLeafId,
                routedSessionId: firstChatId,
                activeLeafId: firstLeafId
            ))
        #expect(
            workspace.isReadAcknowledgementEligible(
                forChat: secondChatId,
                inLeaf: secondLeafId,
                routedSessionId: secondChatId,
                activeLeafId: secondLeafId
            ))
        #expect(
            !workspace.isReadAcknowledgementEligible(
                forChat: backgroundChatId,
                inLeaf: backgroundLeafId,
                routedSessionId: backgroundChatId,
                activeLeafId: backgroundLeafId
            ))
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

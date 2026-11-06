import Foundation
import Testing
@testable import CodevisorCore

@Suite("Child agent panes")
struct WorkspaceChildAgentPaneTests {
  private let parentChatId = UUID()
  private let childChatId = UUID()

  private var chat: PaneDescriptorState {
    PaneDescriptorState(id: UUID(), kind: .chat, name: "Chat", terminalKey: "chat", chatSessionId: parentChatId)
  }

  private var childAgent: PaneDescriptorState {
    PaneDescriptorState(id: UUID(), kind: .childAgent, name: "Child", terminalKey: "child", chatSessionId: childChatId)
  }

  private func workspace(_ pane: PaneDescriptorState) -> Workspace {
    Workspace(
      name: "W", rootDirectory: nil, serverId: "local", projectId: UUID(),
      centerTabs: [WorkspaceTab(root: .leaf(PaneGroupState(panes: [pane], selectedPaneId: pane.id)))],
      createdAt: Date(timeIntervalSince1970: 0))
  }

  @Test("A child agent's split shows its chat without the parent workspace claiming that chat")
  func parentDoesNotClaimChildChat() throws {
    let chat = chat
    var state = workspace(chat)

    let inserted = state.insertPane(childAgent, besidePane: chat.id, destination: .split(.trailing))

    #expect(inserted != nil)
    #expect(state.centerTabs.count == 1)
    #expect(state.chatSessionIds == [parentChatId])
    #expect(state.pane(containingChat: childChatId) == nil)
    #expect(state.pruneOrphanedSubagentPanes().isEmpty)
  }

  @Test("A child agent's split stays on this device: the server never sees it, and syncing keeps it")
  func splitIsDeviceLocal() throws {
    let chat = chat
    let child = childAgent
    var state = workspace(chat)
    _ = state.insertPane(child, besidePane: chat.id, destination: .split(.trailing))
    let records = [ServerPaneMapping.record(from: chat, workspaceId: state.id, createdAt: state.createdAt)]
    let childRecord = ServerPaneMapping.record(from: child, workspaceId: state.id, createdAt: state.createdAt)

    WorkspacePaneReconciler(records: records, protectedLocalPaneIds: []).reconcile(&state)

    #expect(child.kind.isDeviceLocal)
    #expect(ServerPaneMapping.descriptor(from: childRecord) == nil)
    #expect(state.allPanes.map(\.id) == [chat.id, child.id])
  }
}

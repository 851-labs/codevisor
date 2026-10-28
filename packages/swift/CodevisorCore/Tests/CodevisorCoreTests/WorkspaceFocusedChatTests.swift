import Foundation
import Testing
@testable import CodevisorCore

@Suite("Workspace focused chat")
struct WorkspaceFocusedChatTests {
  @Test func followsFocusAcrossASplitOfChats() {
    let first = UUID(), second = UUID()
    let firstLeaf = UUID(), secondLeaf = UUID()
    var workspace = workspace(
      .leaf(group(chat(first)), id: firstLeaf), .leaf(group(chat(second)), id: secondLeaf))

    workspace.centerTabs[0].activeLeafId = secondLeaf
    #expect(workspace.focusedChatSessionId == second)

    workspace.centerTabs[0].activeLeafId = firstLeaf
    #expect(workspace.focusedChatSessionId == first)
  }

  @Test func fallsBackToTheFirstChatWhenFocusIsElsewhere() {
    let first = UUID(), second = UUID()
    let documentLeaf = UUID()
    let document = PaneDescriptorState(
      id: UUID(), kind: .document, name: "README.md", terminalKey: "doc", documentPath: "/tmp/README.md")
    var workspace = workspace(
      .leaf(group(chat(first)), id: UUID()), .leaf(group(chat(second)), id: UUID()),
      .leaf(group(document), id: documentLeaf))

    workspace.centerTabs[0].activeLeafId = documentLeaf
    #expect(workspace.focusedChatSessionId == first)
  }

  private func chat(_ sessionId: UUID) -> PaneDescriptorState {
    PaneDescriptorState(id: UUID(), kind: .chat, name: "Chat", terminalKey: "chat", chatSessionId: sessionId)
  }

  private func group(_ pane: PaneDescriptorState) -> PaneGroupState {
    PaneGroupState(panes: [pane], selectedPaneId: pane.id)
  }

  private func workspace(_ leaves: SplitNode...) -> Workspace {
    Workspace(
      name: "Split", rootDirectory: "/tmp/project", serverId: "local", projectId: UUID(),
      centerTree: .split(
        orientation: .horizontal,
        children: leaves.map { SplitChild(fraction: 1 / Double(leaves.count), node: $0) }))
  }
}

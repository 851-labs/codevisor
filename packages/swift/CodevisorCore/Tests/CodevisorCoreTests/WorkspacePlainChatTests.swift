import Foundation
import Testing
@testable import CodevisorCore

@Suite("A workspace that is only one chat")
struct WorkspacePlainChatTests {
  private func pane(_ kind: PaneKind) -> PaneDescriptorState {
    PaneDescriptorState(id: UUID(), kind: kind, name: kind.rawValue, terminalKey: UUID().uuidString)
  }

  private func group(_ kinds: PaneKind...) -> SplitNode {
    .group(id: UUID(), state: PaneGroupState(panes: kinds.map(pane)))
  }

  private func workspace(_ tree: SplitNode, isArchived: Bool = false) -> Workspace {
    Workspace(
      name: "Workspace", rootDirectory: nil, serverId: "local", projectId: UUID(), centerTree: tree,
      isArchived: isArchived
    )
  }

  @Test("One chat pane on its own is a plain chat")
  func oneChatPane() {
    #expect(workspace(group(.chat)).isPlainChat)
  }

  @Test("A second pane beside the chat, as a tab or as a split, is not a plain chat")
  func extraPane() {
    let split = SplitNode.split(
      orientation: .horizontal,
      children: [SplitChild(fraction: 0.5, node: group(.chat)), SplitChild(fraction: 0.5, node: group(.terminal))]
    )

    #expect(!workspace(group(.chat, .terminal)).isPlainChat)
    #expect(!workspace(split).isPlainChat)
  }

  @Test("A lone pane that is not a chat is not a plain chat")
  func otherKind() {
    #expect(!workspace(group(.browser)).isPlainChat)
  }

  @Test("A second workspace tab is not a plain chat")
  func secondTab() {
    var workspace = workspace(group(.chat))
    workspace.centerTabs.append(WorkspaceTab(root: group(.chat)))

    #expect(!workspace.isPlainChat)
  }

  @Test("An archived workspace is not a plain chat")
  func archived() {
    #expect(!workspace(group(.chat), isArchived: true).isPlainChat)
  }
}

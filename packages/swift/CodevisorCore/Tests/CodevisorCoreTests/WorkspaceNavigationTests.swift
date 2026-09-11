import Foundation
import Testing
@testable import CodevisorCore

struct WorkspaceNavigationTests {
  private func tab(_ kind: PaneKind, chatId: UUID? = nil) -> WorkspaceTab {
    let pane = PaneDescriptorState(
      id: UUID(), kind: kind, name: "Destination", terminalKey: "fixture", chatSessionId: chatId
    )
    return WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [pane], selectedPaneId: pane.id))
    )
  }

  private func workspace(_ tabs: [WorkspaceTab]) -> Workspace {
    Workspace(
      name: "Navigation", rootDirectory: "/navigation-tests", serverId: "machine", projectId: UUID(),
      centerTabs: tabs, createdAt: Date(timeIntervalSince1970: 0)
    )
  }

  @Test(
    "Every pane kind selects its complete destination synchronously",
    arguments: [
      PaneKind.chat, .browser, .plugin, .terminal, .document, .newTab,
    ])
  func selectDestination(kind: PaneKind) throws {
    let loadingChat = tab(.chat, chatId: UUID())
    let destination = tab(kind, chatId: kind == .chat ? UUID() : nil)
    var workspace = workspace([loadingChat, destination])

    workspace.selectDestination(.tab(destination.id))

    // These reads are the first render's inputs. No controller, task,
    // transcript, or mounted container is needed to resolve them.
    #expect(workspace.selectedCenterTabId == destination.id)
    #expect(workspace.centerTree == destination.root)
    let selected = try #require(workspace.selectedCenterTab)
    #expect(selected.activeLeafId == destination.activeLeafId)
    #expect(workspace.selectedPane(inLeaf: selected.activeLeafId)?.kind == kind)
  }

  @Test("An explicit split destination wins over a sibling routing chat")
  func selectSplitLeaf() throws {
    let chat = tab(.chat, chatId: UUID())
    let browser = tab(.browser)
    let browserState = try #require(browser.root.group(id: browser.activeLeafId))
    let split = WorkspaceTab(
      root: chat.root.splitting(
        groupId: chat.activeLeafId, edge: .trailing,
        newGroupId: browser.activeLeafId, newGroupState: browserState
      ),
      activeLeafId: chat.activeLeafId
    )
    var workspace = workspace([tab(.plugin), split])

    workspace.selectDestination(.leaf(browser.activeLeafId))
    #expect(workspace.selectedCenterTabId == split.id)
    #expect(workspace.selectedCenterTab?.activeLeafId == browser.activeLeafId)
    #expect(workspace.selectedPane(inLeaf: browser.activeLeafId)?.kind == .browser)

    // Returning through the tab preserves its selected split.
    workspace.selectDestination(.tab(workspace.centerTabs[0].id))
    workspace.selectDestination(.tab(split.id))
    #expect(workspace.selectedCenterTab?.activeLeafId == browser.activeLeafId)
  }

  @Test("A direct chat link selects the chat inside a legacy group")
  func selectChatInsideGroup() throws {
    let chatId = UUID()
    let chat = PaneDescriptorState(
      id: UUID(), kind: .chat, name: "Chat", terminalKey: "chat", chatSessionId: chatId
    )
    let browser = PaneDescriptorState(id: UUID(), kind: .browser, name: "Browser", terminalKey: "browser")
    let destination = WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [chat, browser], selectedPaneId: browser.id))
    )
    var workspace = workspace([tab(.plugin), destination])

    workspace.selectDestination(.chat(chatId))
    #expect(workspace.selectedCenterTabId == destination.id)
    let state = try #require(workspace.centerTree.group(id: destination.activeLeafId))
    #expect(state.selectedPaneId == chat.id)
  }

  @Test("Rapid navigation leaves the latest destination selected")
  func latestSelectionWins() {
    let chat = tab(.chat, chatId: UUID())
    let browser = tab(.browser)
    let plugin = tab(.plugin)
    var workspace = workspace([chat, browser, plugin])

    for destination in [browser, chat, plugin, browser] {
      workspace.selectDestination(.tab(destination.id))
    }

    #expect(workspace.selectedCenterTabId == browser.id)
    #expect(workspace.centerTree == browser.root)
  }

  @Test("Stale destinations leave selection and layout intact")
  func invalidDestinations() {
    var workspace = workspace([tab(.browser)])
    let original = workspace
    let missing = UUID()
    for destination in [WorkspaceDestination.tab(missing), .leaf(missing), .chat(missing), .pane(missing)] {
      let selected = workspace.selectDestination(destination)
      #expect(!selected)
      #expect(workspace == original)
    }
  }

  @Test(
    "Pane links select all layout levels without constructing content",
    arguments: [PaneKind.chat, .browser, .plugin, .terminal, .document, .newTab])
  func selectPaneInsideGroup(kind: PaneKind) throws {
    let oldPane = PaneDescriptorState(id: UUID(), kind: .chat, name: "Old", terminalKey: "old")
    let target = PaneDescriptorState(id: UUID(), kind: kind, name: "Target", terminalKey: "target")
    let destination = WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [oldPane, target], selectedPaneId: oldPane.id))
    )
    var workspace = workspace([tab(.browser), destination])

    workspace.selectDestination(.pane(target.id))

    #expect(workspace.selectedCenterTabId == destination.id)
    let state = try #require(workspace.centerTree.group(id: destination.activeLeafId))
    #expect(state.selectedPaneId == target.id)
  }

  @Test("A divider preview cannot display the previous tab after navigation")
  func staleTreePreview() {
    let chat = tab(.chat, chatId: UUID())
    let browser = tab(.browser)
    var workspace = workspace([chat, browser])
    let preview = WorkspaceTreePreview(workspace: workspace, tree: chat.root)
    #expect(preview.tree(in: workspace) == chat.root)

    workspace.selectDestination(.tab(browser.id))

    #expect(preview.tree(in: workspace) == nil)
    #expect((preview.tree(in: workspace) ?? workspace.centerTree) == browser.root)
  }

  @Test("A saved layout change supersedes a divider preview in the same tab")
  func updatedTreeSupersedesPreview() {
    let chat = tab(.chat, chatId: UUID())
    var workspace = workspace([chat])
    let preview = WorkspaceTreePreview(workspace: workspace, tree: chat.root)
    workspace.centerTree = tab(.plugin).root

    #expect(preview.tree(in: workspace) == nil)
  }
}

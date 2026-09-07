import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("Browser pane state")
struct BrowserPaneStateTests {
  @Test func conversionAndPersistence() throws {
    let id = UUID()
    var group = PaneGroupState(
      panes: [PaneDescriptorState(id: id, kind: .newTab, name: "New Tab", terminalKey: id.uuidString)],
      selectedPaneId: id)
    let converted = group.convertNewTabPane(id: id, to: .browser, sessionId: UUID())
    let browser = try #require(converted)
    #expect(browser.kind == .browser)
    #expect(browser.browserURL == "https://www.google.com/")
    #expect(group.selectedPaneId == id)
    #expect(try JSONDecoder().decode(PaneGroupState.self, from: JSONEncoder().encode(group)) == group)
  }

  @Test func misplacedBrowsersBecomeWorkspaceTabsWithoutReplacingTheChat() throws {
    let persistence = InMemoryStore()
    let repository = DefaultWorkspaceRepository(store: persistence)
    let sessionId = UUID()
    var workspace = repository.ensureWorkspace(
      for: WorkspaceSessionSeed(
        sessionId: sessionId, initialName: "Example", serverId: "local", projectId: UUID(), rootDirectory: "/fixture"
      ), legacyGroups: nil)
    let chatTab = try #require(workspace.selectedCenterTab)
    let chat = try #require(workspace.pane(containingChat: sessionId))
    let firstId = UUID(), secondId = UUID()
    let browsers = [firstId, secondId].map {
      PaneDescriptorState(
        id: $0, kind: .browser, name: "Emojis", terminalKey: $0.uuidString, browserURL: "https://emojis.com/")
    }
    workspace.centerTabs[0].root = chatTab.root.updatingGroup(id: chatTab.activeLeafId) { state in
      var state = state
      state.panes += browsers
      state.selectedPaneId = secondId
      return state
    }
    repository.save(workspace)

    // Exercise cold-load repair of the exact malformed layout produced by
    // Target.createTarget, including persistence and a second restart.
    let reopened = DefaultWorkspaceRepository(store: persistence)
    let repaired = try #require(reopened.workspace(id: workspace.id))
    #expect(repaired.centerTabs.count == 3)
    #expect(repaired.centerTabs[0].id == chatTab.id)
    #expect(repaired.centerTabs[0].root.group(id: chatTab.activeLeafId)?.panes == [chat])
    #expect(repaired.chatSessionIds == [sessionId])
    for browser in browsers {
      let tab = try #require(repaired.centerTabs.first { $0.id == repaired.tabId(containingPane: browser.id) })
      #expect(tab.root.allGroups.count == 1)
      #expect(tab.root.allGroups[0].state.panes == [browser])
      #expect(tab.id != chatTab.id)
    }
    #expect(repaired.selectedCenterTabId == repaired.tabId(containingPane: secondId))
    #expect(DefaultWorkspaceRepository(store: persistence).workspace(id: workspace.id) == repaired)
  }

  @Test func serverRoundTrip() {
    let id = UUID()
    let browser = PaneDescriptorState(
      id: id, kind: .browser, name: "Dev app", terminalKey: id.uuidString,
      browserURL: "http://localhost:3000/app?q=1#section")
    let record = WorkspaceSyncModel.serverPane(
      from: browser, workspaceId: UUID(), createdAt: Date(timeIntervalSince1970: 0))
    #expect(record.paneType == "browser")
    #expect(record.resourceKind == nil)
    #expect(record.resourceId == nil)
    #expect(record.metadata != nil)
    #expect(WorkspaceSyncModel.descriptor(from: record) == browser)
  }
}

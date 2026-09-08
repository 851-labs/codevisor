import Foundation
import Testing
@testable import CodevisorCore

@Suite("Browser link placement")
struct WorkspaceBrowserLinksTests {
  private func browser(_ name: String) -> PaneDescriptorState {
    let id = UUID()
    return PaneDescriptorState(
      id: id, kind: .browser, name: name, terminalKey: id.uuidString, browserURL: "https://example.com/")
  }
  private func tab(_ pane: PaneDescriptorState) -> WorkspaceTab {
    WorkspaceTab(root: .leaf(PaneGroupState(panes: [pane], selectedPaneId: pane.id, isVisible: true)))
  }
  private func workspace(_ tabs: [WorkspaceTab]) -> Workspace {
    Workspace(
      name: "Links", rootDirectory: nil, serverId: "local", projectId: UUID(), centerTabs: tabs,
      selectedCenterTabId: tabs.last?.id, bottomGroup: PaneGroupState(), createdAt: Date(timeIntervalSince1970: 0))
  }

  @Test(arguments: [BrowserLinkDestination.backgroundTab, .foregroundTab, .window])
  func newTabsStayBesideTheirOpenerWithoutStealingSelection(destination: BrowserLinkDestination) throws {
    let source = browser("Source"), current = browser("Current"), linked = browser("Link")
    let sourceTab = tab(source), currentTab = tab(current)
    var state = workspace([sourceTab, currentTab])
    let insertion = state.insertBrowserPane(linked, from: source.id, destination: destination)
    let result = try #require(insertion)
    #expect(state.centerTabs.map(\.id) == [sourceTab.id, result.tabId, currentTab.id])
    #expect(state.selectedCenterTabId == currentTab.id)
    #expect(state.centerTabs[1].root.group(id: result.leafId)?.panes == [linked])
    #expect(state.centerTabs[0] == sourceTab)
    let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(state))
    #expect(restored.centerTabs == state.centerTabs)
  }

  @Test(arguments: [SplitEdge.leading, .trailing, .top, .bottom])
  func splitUsesTheSourcePaneAndPreservesItsLiveIdentity(edge: SplitEdge) throws {
    let source = browser("Source"), current = browser("Current"), linked = browser("Link")
    let sourceTab = tab(source), currentTab = tab(current)
    var state = workspace([sourceTab, currentTab])
    let insertion = state.insertBrowserPane(linked, from: source.id, destination: .split(edge))
    let result = try #require(insertion)
    #expect(state.centerTabs.count == 2)
    #expect(result.tabId == sourceTab.id)
    #expect(state.centerTabs[0].root.group(id: sourceTab.activeLeafId)?.panes == [source])
    #expect(state.centerTabs[0].root.group(id: result.leafId)?.panes == [linked])
    #expect(state.centerTabs[0].activeLeafId == result.leafId)
    let groups = state.centerTabs[0].root.allGroups.map(\.id)
    #expect(
      groups
        == (edge == .leading || edge == .top
          ? [result.leafId, sourceTab.activeLeafId] : [sourceTab.activeLeafId, result.leafId]))
    #expect(state.selectedCenterTabId == currentTab.id)
    #expect(state.centerTabs[1] == currentTab)
  }

  @Test func closedSourcesAndDuplicatePanesDoNotCreateOrphanTabs() {
    let source = browser("Source")
    var state = workspace([tab(source)])
    let before = state.centerTabs
    let missingSource = state.insertBrowserPane(browser("Link"), from: UUID(), destination: .backgroundTab)
    #expect(missingSource == nil)
    let duplicate = state.insertBrowserPane(source, from: source.id, destination: .split(.trailing))
    #expect(duplicate == nil)
    #expect(state.centerTabs == before)
  }
}

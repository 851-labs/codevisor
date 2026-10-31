import Foundation
import Testing

@testable import CodevisorCore

@Suite("Converted pane title")
struct ConvertedPaneTitleTests {
  private func workspace(centerTree: SplitNode) -> Workspace {
    Workspace(
      name: "Verification",
      rootDirectory: "/tmp/project",
      serverId: "stage3v",
      projectId: UUID(),
      centerTree: centerTree
    )
  }

  @MainActor
  @Test func convertingAPlaceholderPersistsItsNewNameUnderTheSamePaneId() throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    var seeded = PaneGroupState()
    let placeholder = seeded.addNewTabPane()
    let space = workspace(centerTree: .leaf(seeded))
    let leafId = space.centerTree.allGroups[0].id
    repository.save(space)
    let bridge = WorkspacePaneGroupRepository(
      workspaceId: space.id, groupId: leafId, repository: repository)

    var state = try #require(bridge.load(sessionId: nil))
    #expect(state.selectedPane?.name == "New tab")

    let conversion = state.convertNewTabPane(id: placeholder.id, to: .screenSharing, sessionId: nil)
    let converted = try #require(conversion)
    bridge.save(state, sessionId: nil)

    #expect(converted.id == placeholder.id)
    let reloaded = try #require(bridge.load(sessionId: nil))
    #expect(reloaded.selectedPane?.id == placeholder.id)
    #expect(reloaded.selectedPane?.kind == .screenSharing)
    #expect(reloaded.selectedPane?.name == "Screen Sharing")
    #expect(reloaded.selectedPane?.name != "New tab")

    let persisted = try #require(repository.workspace(id: space.id))
    #expect(persisted.centerTree.group(id: leafId)?.selectedPane?.name == "Screen Sharing")
    let layout = try #require(navigation.store.layouts.layout(for: space.id))
    #expect(layout.tabs.first?.root.group(id: leafId)?.selectedPane?.name == "Screen Sharing")
  }

  @MainActor
  @Test func aUserRenamedTabKeepsItsTitleAcrossTheConversion() throws {
    let repository = NavigationFixture().workspaces
    var seeded = PaneGroupState()
    let placeholder = seeded.addNewTabPane()
    var tab = WorkspaceTab(root: .leaf(seeded))
    tab.customTitle = "Remote screen"
    var space = workspace(centerTree: .leaf(PaneGroupState()))
    space.centerTabs = [tab]
    space.selectedCenterTabId = tab.id
    let leafId = try #require(tab.root.allGroups.first?.id)
    repository.save(space)
    let bridge = WorkspacePaneGroupRepository(workspaceId: space.id, groupId: leafId, repository: repository)

    var state = try #require(bridge.load(sessionId: nil))
    let conversion = state.convertNewTabPane(id: placeholder.id, to: .screenSharing, sessionId: nil)
    _ = try #require(conversion)
    bridge.save(state, sessionId: nil)

    let persisted = try #require(repository.workspace(id: space.id)?.centerTabs.first { $0.id == tab.id })
    #expect(persisted.root.group(id: leafId)?.selectedPane?.name == "Screen Sharing")
    #expect(persisted.customTitle == "Remote screen")
  }
}

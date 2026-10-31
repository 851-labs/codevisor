import Foundation
import Testing

@testable import CodevisorCore

@Suite("Chatless workspace panes")
struct ChatlessWorkspacePaneTests {
  private func workspace(centerTree: SplitNode) -> Workspace {
    Workspace(
      name: "Verification",
      rootDirectory: "/tmp/project",
      serverId: "stage3v",
      projectId: UUID(),
      centerTree: centerTree
    )
  }

  @Test func aCenterGroupWithoutAChatStartsOnTheNewTabPage() {
    let state = PaneGroupState.centerInitialWithoutChat()

    #expect(state.panes.count == 1)
    #expect(state.panes[0].kind == .newTab)
    #expect(state.panes[0].chatSessionId == nil)
    #expect(state.selectedPaneId == state.panes[0].id)
    let space = workspace(centerTree: .leaf(state))
    #expect(space.selectedCenterTab?.root.allGroups.first?.state == state)
    #expect(state.panes[0].terminalKey == state.panes[0].id.uuidString)
  }

  @Test func theSessionKeyedStoreDeclinesAGroupWithoutASession() {
    let legacy = DefaultPaneGroupRepository(store: InMemoryStore())
    var state = PaneGroupState()
    state.addNewTabPane()

    legacy.save(state, sessionId: nil)
    #expect(legacy.load(sessionId: nil) == nil)

    let session = UUID()
    legacy.save(state, sessionId: session)
    #expect(legacy.load(sessionId: session) == state)
    #expect(legacy.load(sessionId: nil) == nil)
  }

  @Test func convertingAPlaceholderWithoutASessionRefusesOnlyTheTerminal() {
    var state = PaneGroupState.centerInitialWithoutChat()
    let paneId = state.panes[0].id

    #expect(state.convertNewTabPane(id: paneId, to: .terminal, sessionId: nil) == nil)
    #expect(state.panes[0].kind == .newTab)

    let converted = state.convertNewTabPane(id: paneId, to: .screenSharing, sessionId: nil)
    #expect(converted?.kind == .screenSharing)
    #expect(converted?.terminalKey == paneId.uuidString)
    #expect(converted?.chatSessionId == nil)
  }

  @Test func aTerminalStillConvertsWhenARealSessionIsPresent() {
    var state = PaneGroupState.centerInitialWithoutChat()
    let paneId = state.panes[0].id
    let session = UUID()

    let converted = state.convertNewTabPane(id: paneId, to: .terminal, sessionId: session)
    #expect(converted?.kind == .terminal)
    #expect(converted?.terminalKey == "\(session.uuidString):\(paneId.uuidString)")
  }

  @Test func paneWorkAnchorsOnTheChatWhenThereIsOneAndOnTheWorkspaceOtherwise() {
    let workspaceRoot = "/tmp/project/.worktrees/verification"
    let projectRoot = "/tmp/project"

    #expect(
      PaneWorkingDirectory.resolve(
        anchor: .session(cwd: "/tmp/project/.worktrees/chat"),
        workspaceRootDirectory: workspaceRoot, projectFolderPath: projectRoot)
        == "/tmp/project/.worktrees/chat")
    #expect(
      PaneWorkingDirectory.resolve(
        anchor: .session(cwd: nil), workspaceRootDirectory: workspaceRoot,
        projectFolderPath: projectRoot) == projectRoot)

    #expect(
      PaneWorkingDirectory.resolve(
        anchor: .workspace, workspaceRootDirectory: workspaceRoot, projectFolderPath: projectRoot)
        == workspaceRoot)
    #expect(
      PaneWorkingDirectory.resolve(
        anchor: .workspace, workspaceRootDirectory: nil, projectFolderPath: projectRoot)
        == projectRoot)
  }
}

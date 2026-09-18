import Foundation
import Testing

@testable import CodevisorCore

/// A workspace can exist before any chat does. These pin the pane-layer
/// contracts that makes such a workspace usable without inventing a session:
/// its layout persists by workspace identity, its first center group is the
/// ordinary New Tab page, and anything that needs a real session identity
/// declines instead of fabricating one.
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
    // The placeholder keys on its own pane id, never on a session.
    #expect(state.panes[0].terminalKey == state.panes[0].id.uuidString)
  }

  @Test func workspaceKeyedPanesPersistWithoutASessionKey() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    var space = workspace(centerTree: .leaf(PaneGroupState.centerInitialWithoutChat()))
    let leafId = space.centerTree.allGroups[0].id
    repository.save(space)

    let bridge = WorkspacePaneGroupRepository(
      workspaceId: space.id, groupId: leafId, repository: repository)

    // Loading with no session key still finds the workspace's own leaf state.
    let loaded = bridge.load(sessionId: nil)
    #expect(loaded?.panes.first?.kind == .newTab)

    var updated = try! #require(loaded)
    updated.addNewTabPane()
    bridge.save(updated, sessionId: nil)

    let reloaded = bridge.load(sessionId: nil)
    #expect(reloaded?.panes.count == 2)
    space = try! #require(repository.workspace(id: space.id))
    #expect(space.centerTree.group(id: leafId)?.panes.count == 2)
  }

  @Test func theSessionKeyedStoreDeclinesAGroupWithoutASession() {
    let legacy = DefaultPaneGroupRepository(store: InMemoryStore())
    var state = PaneGroupState()
    state.addNewTabPane()

    // Saving without a key is a no-op rather than a substitute key that could
    // collide with a real session's legacy entry.
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
    #expect(state.panes[0].kind == .newTab)  // the placeholder survives untouched

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

  /// End to end over the real models: a workspace authored on the server with
  /// no chat (an older client's "new-tab" row is ignored — the page is
  /// device-local) reconciles into a usable layout showing this device's own
  /// New Tab page, its leaf is selectable, and activating it addresses the
  /// workspace itself.
  @Test @MainActor func aServerAuthoredChatlessWorkspaceBecomesSelectableLayout() throws {
    var space = workspace(centerTree: .leaf(PaneGroupState()))
    let record = ServerWorkspacePane(
      id: UUID().uuidString,
      workspaceId: space.id.uuidString,
      providerId: "codevisor",
      paneType: "new-tab",
      title: "New tab",
      createdAt: "2026-09-13T00:00:00.000Z"
    )

    WorkspaceSyncModel.reconcilePanes(in: &space, records: [record], protectedLocalPaneIds: [])

    #expect(space.allPanes.count == 1)
    let pane = try #require(space.allPanes.first)
    #expect(pane.kind == .newTab)
    #expect(pane.id.uuidString != record.id)
    let leafId = try #require(
      space.centerTabs.flatMap { $0.root.allGroups }.first { $0.state.panes.contains { $0.id == pane.id } }?.id)

    let selected = space.selectDestination(.leaf(leafId))
    #expect(selected)

    // No chat in the destination, none in the workspace, nothing already
    // routed: the selection must address the workspace.
    #expect(
      space.selectionRoute(
        activatedChatSessionId: nil, routingSessionId: nil, selectionAlreadyRoutesWorkspace: false)
        == .workspace(serverId: space.serverId, id: space.id))
  }

  /// The transition root asked to pin: the SAME leaf is entered first without a
  /// chat and then with one. Once the placeholder becomes a real chat pane, the
  /// leaf routes to that chat instead of the workspace, which is what remounts
  /// the container as `.chat` and lets the cached group adopt the session.
  @Test func aLeafThatGainsAChatRoutesToItInsteadOfTheWorkspace() throws {
    var space = workspace(centerTree: .leaf(PaneGroupState.centerInitialWithoutChat()))
    let leafId = space.centerTree.allGroups[0].id
    let placeholderId = try #require(space.centerTree.group(id: leafId)?.panes.first?.id)

    // Before: no chat anywhere, so activating the leaf addresses the workspace.
    #expect(
      space.selectionRoute(
        activatedChatSessionId: nil, routingSessionId: nil, selectionAlreadyRoutesWorkspace: false)
        == .workspace(serverId: space.serverId, id: space.id))

    // The ordinary user-triggered creation path binds a real session to the
    // placeholder in place (no new pane, no fabricated identity).
    let chat = UUID()
    var state = try #require(space.centerTree.group(id: leafId))
    let conversion = state.convertNewTabPane(
      id: placeholderId, to: .chat, sessionId: nil, chatSessionId: chat)
    let converted = try #require(conversion)
    space.centerTree = space.centerTree.updatingGroup(id: leafId) { _ in state }

    #expect(converted.id == placeholderId)  // same slot, live pane preserved
    #expect(converted.chatSessionId == chat)
    #expect(space.centerTree.groupId(containingChat: chat) == leafId)

    // After: the same activation now resolves to the real chat.
    #expect(
      space.selectionRoute(
        activatedChatSessionId: chat, routingSessionId: nil, selectionAlreadyRoutesWorkspace: false)
        == .session(serverId: space.serverId, id: chat))
  }

  @Test func paneWorkAnchorsOnTheChatWhenThereIsOneAndOnTheWorkspaceOtherwise() {
    let workspaceRoot = "/tmp/project/.worktrees/verification"
    let projectRoot = "/tmp/project"

    // Session-rooted behaviour is untouched: its cwd wins, project folder backs it.
    #expect(
      PaneWorkingDirectory.resolve(
        anchor: .session(cwd: "/tmp/project/.worktrees/chat"),
        workspaceRootDirectory: workspaceRoot, projectFolderPath: projectRoot)
        == "/tmp/project/.worktrees/chat")
    #expect(
      PaneWorkingDirectory.resolve(
        anchor: .session(cwd: nil), workspaceRootDirectory: workspaceRoot,
        projectFolderPath: projectRoot) == projectRoot)

    // No chat: the workspace's OWN directory, not the project root.
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

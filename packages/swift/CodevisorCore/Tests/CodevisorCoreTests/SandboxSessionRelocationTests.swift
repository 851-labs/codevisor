import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Moving a first-send chat onto its sandbox")
struct SandboxSessionRelocationTests {
  private let navigation = NavigationFixture()
  private let owner = Project(id: UUID(), serverId: "local", name: "hello-world")
  private let remote = Project(id: UUID(), serverId: "cloud:vm", name: "hello-world")

  @Test("The chat's workspace moves to the new machine and stays routed once that machine lists it")
  func workspaceFollowsTheChat() async {
    await navigation.install(projects: [owner])
    let previous = navigation.projectList.newSession(in: owner, title: "Hi", syncToServer: false)
    let draft = draftWorkspace(for: previous)
    let relocated = moved(previous)

    SandboxSessionRelocation.relocate(
      previous, to: relocated, project: remote,
      projectList: navigation.projectList, workspaces: navigation.workspaces)
    await listOnRemote(relocated, workspace: SandboxSessionRelocation.relocatedWorkspace(draft, to: remote))

    #expect(navigation.workspaces.workspace(id: draft.id)?.serverId == remote.serverId)
    #expect(navigation.store.layouts.draft(id: draft.id) == nil)
    #expect(
      navigation.workspaceSync.routeDisposition(
        sessionId: relocated.id, serverId: remote.serverId, preservingSelectedPane: true) == .keep)
  }

  @Test("A route opened on the old machine keeps showing the chat the moment it moves")
  func routeFollowsTheMovedWorkspace() async {
    await navigation.install(projects: [owner])
    let previous = navigation.projectList.newSession(in: owner, title: "Hi", syncToServer: false)
    let draft = draftWorkspace(for: previous)

    SandboxSessionRelocation.relocate(
      previous, to: moved(previous), project: remote,
      projectList: navigation.projectList, workspaces: navigation.workspaces)

    #expect(navigation.workspaceSync.routeDisposition(workspaceId: draft.id, anchorSessionId: previous.id) == .keep)
  }

  @Test("A side chat opened while the sandbox was starting moves with the workspace, and the Mac gets no copy")
  func sideChatFollowsTheWorkspace() async {
    await navigation.install(projects: [owner])
    let previous = navigation.projectList.newSession(in: owner, title: "Hi", syncToServer: false)
    let draft = draftWorkspace(for: previous)
    let side = navigation.projectList.newSession(
      in: owner, title: "New Chat", cwd: "/owner/hello-world", syncToServer: false)
    let pane = PaneDescriptorState(
      id: UUID(), kind: .chat, name: "New Chat", terminalKey: "side", chatSessionId: side.id)
    navigation.store.enqueue(.promotePane(pane, workspaceId: draft.id, session: side), machineId: owner.serverId)

    let carried = SandboxSessionRelocation.relocate(
      previous, to: moved(previous), project: remote,
      projectList: navigation.projectList, workspaces: navigation.workspaces)

    #expect(carried.map(\.relocated.id) == [side.id])
    #expect(carried.first?.relocated.serverId == remote.serverId)
    #expect(carried.first?.relocated.projectId == remote.id)
    #expect(carried.first?.relocated.cwd == nil)
    let queued = navigation.store.pendingIntents
    #expect(!queued.contains { $0.machineId == owner.serverId && $0.intent.workspaceId == draft.id })
    #expect(!queued.contains { $0.machineId == owner.serverId && $0.intent.expectedSessionId == side.id })
    #expect(
      queued.contains { entry in
        guard entry.machineId == remote.serverId, case let .promotePane(_, workspaceId, session) = entry.intent
        else { return false }
        return workspaceId == draft.id && session.id == side.id && session.projectId == remote.id
      })
  }

  private func draftWorkspace(for session: ChatSession) -> Workspace {
    navigation.workspaces.ensureWorkspace(
      for: WorkspaceSessionSeed(
        sessionId: session.id, initialName: owner.name, serverId: owner.serverId, projectId: owner.id,
        rootDirectory: "/owner/hello-world", worktreeName: nil, assignedWorkspaceId: nil),
      legacyGroups: nil)
  }

  private func moved(_ session: ChatSession) -> ChatSession {
    var relocated = session
    relocated.serverId = remote.serverId
    relocated.projectId = remote.id
    return relocated
  }

  private func listOnRemote(_ session: ChatSession, workspace: Workspace) async {
    var listed = workspace
    listed.isServerSynced = true
    await navigation.install(
      machineId: remote.serverId, projects: [remote], sessions: [session], workspaces: [listed])
  }
}

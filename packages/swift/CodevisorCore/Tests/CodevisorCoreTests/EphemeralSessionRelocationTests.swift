import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Moving a first-send chat onto its ephemeral machine")
struct EphemeralSessionRelocationTests {
  private let navigation = NavigationFixture()
  private let owner = Project(id: UUID(), serverId: "local", name: "hello-world")
  private let remote = Project(id: UUID(), serverId: "cloud:vm", name: "hello-world")

  @Test("The chat's workspace moves to the new machine and stays routed once that machine lists it")
  func workspaceFollowsTheChat() async {
    await navigation.install(projects: [owner])
    let previous = navigation.projectList.newSession(in: owner, title: "Hi", syncToServer: false)
    let draft = draftWorkspace(for: previous)
    let relocated = moved(previous)

    EphemeralSessionRelocation.relocate(
      previous, to: relocated, project: remote,
      projectList: navigation.projectList, workspaces: navigation.workspaces)
    await listOnRemote(relocated, workspace: EphemeralSessionRelocation.relocatedWorkspace(draft, to: remote))

    #expect(navigation.workspaces.workspace(id: draft.id)?.serverId == remote.serverId)
    #expect(navigation.store.layouts.draft(id: draft.id) == nil)
    #expect(
      navigation.workspaceSync.routeDisposition(
        sessionId: relocated.id, serverId: remote.serverId, preservingSelectedPane: true) == .keep)
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

import Foundation
import Testing

@testable import CodevisorCore

/// How `ensureWorkspace` honors the server's session→workspace assignment:
/// the server's index wins, a known assigned workspace is joined, and only a
/// chat nobody placed gets a draft -- under the server's identity when the
/// server already named it.
@MainActor
@Suite("Workspace assignment routing")
struct WorkspaceAssignmentRoutingTests {
  private let projectId = UUID()

  private func seed(
    sessionId: UUID = UUID(),
    initialName: String = "Example Project",
    serverId: String = "local",
    root: String? = "/tmp/checkout",
    assignedWorkspaceId: UUID? = nil
  ) -> WorkspaceSessionSeed {
    WorkspaceSessionSeed(
      sessionId: sessionId,
      initialName: initialName,
      serverId: serverId,
      projectId: projectId,
      rootDirectory: root,
      assignedWorkspaceId: assignedWorkspaceId
    )
  }

  /// A server workspace holding one chat, installed from a snapshot.
  private func serverWorkspace(
    serverId: String = "local", chat: UUID = UUID(), isArchived: Bool = false
  ) -> (Workspace, ChatSession) {
    let workspace = Workspace(
      name: "Host", rootDirectory: "/tmp/roquefort", serverId: serverId, projectId: projectId,
      centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: chat, paneId: chat)))],
      isArchived: isArchived, isServerSynced: true)
    return (workspace, ChatSession(id: chat, projectId: projectId, serverId: serverId))
  }

  @Test("A server-assigned chat joins its workspace instead of minting a draft")
  func assignedChatJoinsExistingWorkspace() async throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let (host, chat) = serverWorkspace()
    await navigation.install(sessions: [chat], workspaces: [host])
    let selectedTab = try #require(repository.workspace(id: host.id)?.selectedCenterTabId)
    let newcomer = seed(root: "/tmp/roquefort", assignedWorkspaceId: host.id)

    let resolved = repository.ensureWorkspace(for: newcomer, legacyGroups: nil)

    #expect(resolved.id == host.id)
    #expect(resolved.isServerSynced)
    #expect(repository.loadAll().count == 1)
    #expect(navigation.store.layouts.drafts.isEmpty)
    // Joining never steals the user's place in the host workspace.
    #expect(resolved.selectedCenterTabId == selectedTab)
    // The chat's pane arrives with the server's copy of the assignment.
    var assigned = serverSession(from: ChatSession(id: newcomer.sessionId, projectId: projectId))
    assigned.workspaceId = host.id.uuidString
    let pane = ServerWorkspacePane(
      id: newcomer.sessionId.uuidString, workspaceId: host.id.uuidString, providerId: "codevisor",
      paneType: "chat", title: "Chat", resourceKind: "session", resourceId: newcomer.sessionId.uuidString,
      createdAt: "2026-06-30T00:00:00.000Z")
    _ = await navigation.store.apply(.fixture(cursor: 2, sessions: [assigned], panes: [pane]), machineId: "local")
    #expect(repository.workspaceId(forSession: newcomer.sessionId) == host.id)
    #expect(repository.workspace(id: host.id)?.chatSessionIds.contains(newcomer.sessionId) == true)
    #expect(repository.ensureWorkspace(for: newcomer, legacyGroups: nil).id == host.id)
    #expect(repository.loadAll().count == 1)
  }

  @Test("An assignment to a workspace this device hasn't seen drafts it under the server's identity")
  func assignedChatMintsWithServerIdentity() {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let serverWorkspaceId = UUID()
    let assigned = seed(initialName: "roquefort", root: "/tmp/roquefort", assignedWorkspaceId: serverWorkspaceId)

    let minted = repository.ensureWorkspace(for: assigned, legacyGroups: nil)

    #expect(minted.id == serverWorkspaceId)
    #expect(minted.isDraft)
    #expect(minted.pane(containingChat: assigned.sessionId)?.id == assigned.sessionId)
    #expect(repository.workspaceId(forSession: assigned.sessionId) == serverWorkspaceId)
    #expect(navigation.store.layouts.draft(id: serverWorkspaceId) != nil)
  }

  @Test("An assignment to an archived workspace returns it; one to another machine's drafts a fresh one")
  func assignedChatEligibility() async throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let (archived, archivedChat) = serverWorkspace(isArchived: true)
    let (remote, remoteChat) = serverWorkspace(serverId: "cloud:a")
    await navigation.install(sessions: [archivedChat], workspaces: [archived])
    await navigation.install(machineId: "cloud:a", sessions: [remoteChat], workspaces: [remote])

    let intoArchived = repository.ensureWorkspace(
      for: seed(initialName: "A", assignedWorkspaceId: archived.id), legacyGroups: nil)
    let intoRemote = repository.ensureWorkspace(
      for: seed(initialName: "B", root: "/tmp/remote", assignedWorkspaceId: remote.id), legacyGroups: nil)

    // Reopening a chat in an archived workspace is the caller's revival.
    #expect(intoArchived.id == archived.id)
    #expect(intoRemote.id != remote.id)
    #expect(intoRemote.isDraft)
    #expect(repository.workspace(id: remote.id)?.chatSessionIds == [remoteChat.id])
    #expect(repository.workspace(id: remote.id)?.isServerSynced == true)
    #expect(repository.loadAll().count == 3)
  }

  @Test("Once the server places a drafted chat elsewhere, the chat routes there")
  func draftedChatFollowsTheServerAssignment() async throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let (host, hostChat) = serverWorkspace()
    await navigation.install(sessions: [hostChat], workspaces: [host])
    // The chat arrived before its assignment was known: a draft was made.
    let raced = seed(root: "/tmp/roquefort")
    let draft = repository.ensureWorkspace(for: raced, legacyGroups: nil)
    #expect(draft.isDraft)
    #expect(repository.workspaceId(forSession: raced.sessionId) == draft.id)

    var assigned = serverSession(from: ChatSession(id: raced.sessionId, projectId: projectId))
    assigned.workspaceId = host.id.uuidString
    _ = await navigation.store.apply(.fixture(cursor: 2, sessions: [assigned]), machineId: "local")

    #expect(repository.workspaceId(forSession: raced.sessionId) == host.id)
    #expect(repository.ensureWorkspace(for: raced, legacyGroups: nil).id == host.id)
  }

  @Test("The server's index wins over a conflicting seed assignment")
  func indexWinsOverAssignment() async throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let (host, hostChat) = serverWorkspace()
    let (owner, ownerChat) = serverWorkspace()
    await navigation.install(sessions: [hostChat, ownerChat], workspaces: [host, owner])
    let drafted = repository.ensureWorkspace(for: seed(), legacyGroups: nil)
    let draftedChat = try #require(drafted.chatSessionIds.first)

    for (chat, workspace) in [(ownerChat.id, owner.id), (draftedChat, drafted.id)] {
      let conflicting = seed(sessionId: chat, initialName: "X", assignedWorkspaceId: host.id)
      #expect(repository.ensureWorkspace(for: conflicting, legacyGroups: nil).id == workspace)
      #expect(repository.workspaceId(forSession: chat) == workspace)
    }
    #expect(repository.loadAll().count == 3)
    #expect(repository.workspace(id: host.id)?.chatSessionIds == [hostChat.id])
  }
}

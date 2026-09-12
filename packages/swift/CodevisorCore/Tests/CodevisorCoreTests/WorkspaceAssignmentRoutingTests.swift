import Foundation
import Testing
@testable import CodevisorCore

/// How `ensureWorkspace` honors the server's session→workspace assignment:
/// join a known workspace, mint under the server's identity, and re-home a
/// chat this client minted a sibling for before the assignment was known.
@Suite("Workspace assignment routing")
struct WorkspaceAssignmentRoutingTests {
  private func seed(
    sessionId: UUID = UUID(),
    initialName: String = "Example Project",
    serverId: String = "local",
    projectId: UUID = UUID(),
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

  @Test("A server-assigned chat joins its workspace instead of minting a sibling")
  func assignedChatJoinsExistingWorkspace() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let host = repository.ensureWorkspace(for: seed(root: "/tmp/roquefort"), legacyGroups: nil)
    let selectedTab = host.selectedCenterTabId
    let newcomer = seed(root: "/tmp/roquefort", assignedWorkspaceId: host.id)

    let resolved = repository.ensureWorkspace(for: newcomer, legacyGroups: nil)

    #expect(resolved.id == host.id)
    #expect(repository.loadAll().count == 1)
    #expect(repository.workspaceId(forSession: newcomer.sessionId) == host.id)
    #expect(resolved.chatSessionIds.contains(newcomer.sessionId))
    // Joining never steals the user's place in the host workspace.
    #expect(resolved.selectedCenterTabId == selectedTab)
    // Re-ensuring routes through the index and adds nothing.
    let again = repository.ensureWorkspace(for: newcomer, legacyGroups: nil)
    #expect(again.centerTabs.count == resolved.centerTabs.count)
  }

  @Test("An assignment to an unknown workspace mints under the server's identity")
  func assignedChatMintsWithServerIdentity() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let serverWorkspaceId = UUID()
    let assigned = seed(
      initialName: "roquefort", root: "/tmp/roquefort", assignedWorkspaceId: serverWorkspaceId
    )

    let minted = repository.ensureWorkspace(for: assigned, legacyGroups: nil)

    #expect(minted.id == serverWorkspaceId)
    #expect(minted.isServerSynced == false)
    #expect(repository.workspaceId(forSession: assigned.sessionId) == serverWorkspaceId)
  }

  @Test("Assignments to archived or other-machine workspaces mint a fresh workspace")
  func assignedChatIgnoresIneligibleWorkspaces() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    var archived = repository.ensureWorkspace(for: seed(), legacyGroups: nil)
    archived.isArchived = true
    repository.save(archived)
    let remote = repository.ensureWorkspace(
      for: seed(initialName: "Remote", serverId: "cloud:a", root: "/tmp/remote"),
      legacyGroups: nil
    )

    let intoArchived = repository.ensureWorkspace(
      for: seed(initialName: "A", assignedWorkspaceId: archived.id),
      legacyGroups: nil
    )
    let intoRemote = repository.ensureWorkspace(
      for: seed(initialName: "B", root: "/tmp/remote", assignedWorkspaceId: remote.id),
      legacyGroups: nil
    )

    #expect(intoArchived.id != archived.id)
    #expect(intoRemote.id != remote.id)
    #expect(repository.workspace(id: archived.id)?.isArchived == true)
    #expect(repository.workspace(id: remote.id)?.chatSessionIds.count == 1)
    #expect(repository.loadAll().count == 4)
  }

  @Test("A minted workspace re-homes its chat once the server names a sibling")
  func mintedWorkspaceRehomesToAssignedSibling() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let host = repository.ensureWorkspace(for: seed(root: "/tmp/roquefort"), legacyGroups: nil)
    // The chat arrived before its assignment was known: a sibling was
    // minted at the same directory and the user opened a terminal in it.
    let raced = seed(root: "/tmp/roquefort")
    var minted = repository.ensureWorkspace(for: raced, legacyGroups: nil)
    let terminal = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: "Terminal 1", terminalKey: "term-1"
    )
    _ = minted.upsertCenterPane(terminal)
    repository.save(minted)
    #expect(repository.loadAll().count == 2)

    let assigned = seed(
      sessionId: raced.sessionId, root: raced.rootDirectory, assignedWorkspaceId: host.id
    )
    let resolved = repository.ensureWorkspace(for: assigned, legacyGroups: nil)

    #expect(resolved.id == host.id)
    #expect(repository.loadAll().map(\.id) == [host.id])
    #expect(repository.workspaceId(forSession: raced.sessionId) == host.id)
    #expect(resolved.chatSessionIds.contains(raced.sessionId))
    #expect(resolved.allPanes.contains { $0.id == terminal.id })
  }

  @Test("Server-confirmed and multi-chat workspaces keep their routing despite a conflicting assignment")
  func confirmedRoutingWinsOverAssignment() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let host = repository.ensureWorkspace(for: seed(), legacyGroups: nil)

    var synced = repository.ensureWorkspace(for: seed(), legacyGroups: nil)
    synced.isServerSynced = true
    repository.save(synced)
    let syncedChat = synced.chatSessionIds[0]

    let shared = repository.ensureWorkspace(for: seed(), legacyGroups: nil)
    let sharedChat = shared.chatSessionIds[0]
    var sharedWithSibling = shared
    sharedWithSibling.centerTabs.append(
      WorkspaceTab(root: .leaf(.centerInitial(sessionId: UUID())))
    )
    repository.save(sharedWithSibling)

    for (chat, workspace) in [(syncedChat, synced), (sharedChat, shared)] {
      let conflicting = seed(
        sessionId: chat, initialName: "X", projectId: workspace.projectId,
        root: workspace.rootDirectory, assignedWorkspaceId: host.id
      )
      let resolved = repository.ensureWorkspace(for: conflicting, legacyGroups: nil)
      #expect(resolved.id == workspace.id)
      #expect(repository.workspaceId(forSession: chat) == workspace.id)
    }
    #expect(repository.loadAll().count == 3)
    #expect(repository.workspace(id: host.id)?.chatSessionIds.count == 1)
  }
}

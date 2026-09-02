import Foundation
import Testing
@testable import CodevisorCore

@Suite("Workspace worktree split migration")
struct WorkspaceWorktreeSplitMigrationTests {
  private let projectId = UUID()

  private func makeRepository() -> DefaultWorkspaceRepository {
    DefaultWorkspaceRepository(store: InMemoryStore())
  }

  private func chatState(sessionId: UUID) -> PaneGroupState {
    .centerInitial(sessionId: sessionId)
  }

  private func workspace(
    rootDirectory: String?,
    worktreeName: String? = nil,
    chatIds: [UUID]
  ) -> Workspace {
    Workspace(
      name: "Original",
      rootDirectory: rootDirectory,
      worktreeName: worktreeName,
      serverId: "local",
      projectId: projectId,
      centerTabs: chatIds.map { WorkspaceTab(root: .leaf(chatState(sessionId: $0))) },
      bottomGroup: .initial(sessionId: chatIds[0])
    )
  }

  private func context(
    _ id: UUID, worktreeName: String? = nil, cwd: String?
  ) -> WorkspaceWorktreeSplitMigration.SessionContext {
    .init(sessionId: id, worktreeName: worktreeName, cwd: cwd)
  }

  @Test("A single-directory workspace is stamped, not split")
  func stampsSingleGroup() {
    let repository = makeRepository()
    let chat = UUID()
    repository.save(workspace(rootDirectory: nil, chatIds: [chat]))

    let ran = WorkspaceWorktreeSplitMigration.runIfNeeded(
      workspaces: repository,
      sessions: [context(chat, worktreeName: "kiwi", cwd: "/wt/kiwi")],
      projectNames: [projectId: "repo"]
    )

    #expect(ran)
    let all = repository.loadAll()
    #expect(all.count == 1)
    #expect(all[0].worktreeName == "kiwi")
    #expect(all[0].rootDirectory == "/wt/kiwi")
  }

  @Test("A mixed workspace splits each worktree group into its own workspace")
  func splitsMixedWorkspace() {
    let repository = makeRepository()
    let rootChat = UUID()
    let worktreeChat = UUID()
    let original = workspace(
      rootDirectory: "/repo", chatIds: [rootChat, worktreeChat]
    )
    repository.save(original)
    let movedPaneId = original.centerTabs[1].root.allGroups[0].state.panes[0].id

    WorkspaceWorktreeSplitMigration.runIfNeeded(
      workspaces: repository,
      sessions: [
        context(rootChat, cwd: "/repo"),
        context(worktreeChat, worktreeName: "kiwi", cwd: "/wt/kiwi"),
      ],
      projectNames: [projectId: "repo"]
    )

    let all = repository.loadAll()
    #expect(all.count == 2)
    let kept = all.first { $0.id == original.id }
    let split = all.first { $0.id != original.id }
    // The original keeps its identity, root chat, and directory.
    #expect(kept?.worktreeName == nil)
    #expect(kept?.rootDirectory == "/repo")
    #expect(kept?.chatSessionIds == [rootChat])
    #expect(kept?.centerTabs.count == 1)
    // The worktree chat moved into a workspace named after its worktree,
    // preserving the pane's identity.
    #expect(split?.name == "kiwi")
    #expect(split?.worktreeName == "kiwi")
    #expect(split?.rootDirectory == "/wt/kiwi")
    #expect(split?.chatSessionIds == [worktreeChat])
    #expect(split?.centerTabs.first?.root.allGroups.first?.state.panes.first?.id == movedPaneId)
    #expect(split?.bottomGroup.panes.isEmpty == true)
    // The session index routes the moved chat to its new workspace.
    #expect(repository.workspaceId(forSession: worktreeChat) == split?.id)
    #expect(repository.workspaceId(forSession: rootChat) == original.id)
  }

  @Test("A worktree-rooted workspace keeps its worktree group as primary")
  func worktreeRootedPrimary() {
    let repository = makeRepository()
    let rootChat = UUID()
    let worktreeChat = UUID()
    let original = workspace(
      rootDirectory: "/wt/kiwi", chatIds: [worktreeChat, rootChat]
    )
    repository.save(original)

    WorkspaceWorktreeSplitMigration.runIfNeeded(
      workspaces: repository,
      sessions: [
        context(rootChat, cwd: "/repo"),
        context(worktreeChat, worktreeName: "kiwi", cwd: "/wt/kiwi"),
      ],
      projectNames: [projectId: "repo"]
    )

    let all = repository.loadAll()
    let kept = all.first { $0.id == original.id }
    let split = all.first { $0.id != original.id }
    #expect(kept?.worktreeName == "kiwi")
    #expect(kept?.chatSessionIds == [worktreeChat])
    // The project-root chat splits out under the project's name.
    #expect(split?.name == "repo")
    #expect(split?.worktreeName == nil)
    #expect(split?.rootDirectory == "/repo")
    #expect(split?.chatSessionIds == [rootChat])
  }

  @Test("Chats with no local session record group with the project root")
  func unknownSessionsGroupAsRoot() {
    let repository = makeRepository()
    let knownChat = UUID()
    let unknownChat = UUID()
    let original = workspace(
      rootDirectory: "/repo", chatIds: [knownChat, unknownChat]
    )
    repository.save(original)

    WorkspaceWorktreeSplitMigration.runIfNeeded(
      workspaces: repository,
      sessions: [context(knownChat, cwd: "/repo")],
      projectNames: [projectId: "repo"]
    )

    // Both chats resolve to the root group — no split.
    let all = repository.loadAll()
    #expect(all.count == 1)
    #expect(Set(all[0].chatSessionIds) == [knownChat, unknownChat])
  }

  @Test("The migration runs once")
  func idempotent() {
    let repository = makeRepository()
    let rootChat = UUID()
    let worktreeChat = UUID()
    repository.save(workspace(rootDirectory: "/repo", chatIds: [rootChat, worktreeChat]))
    let sessions = [
      context(rootChat, cwd: "/repo"),
      context(worktreeChat, worktreeName: "kiwi", cwd: "/wt/kiwi"),
    ]

    let first = WorkspaceWorktreeSplitMigration.runIfNeeded(
      workspaces: repository, sessions: sessions, projectNames: [:]
    )
    let countAfterFirst = repository.loadAll().count
    let second = WorkspaceWorktreeSplitMigration.runIfNeeded(
      workspaces: repository, sessions: sessions, projectNames: [:]
    )

    #expect(first)
    #expect(!second)
    #expect(repository.loadAll().count == countAfterFirst)
  }

  @Test("Archived workspaces split too, inheriting the archived state")
  func archivedWorkspacesSplit() {
    let repository = makeRepository()
    let rootChat = UUID()
    let worktreeChat = UUID()
    var original = workspace(rootDirectory: "/repo", chatIds: [rootChat, worktreeChat])
    original.isArchived = true
    repository.save(original)

    WorkspaceWorktreeSplitMigration.runIfNeeded(
      workspaces: repository,
      sessions: [
        context(rootChat, cwd: "/repo"),
        context(worktreeChat, worktreeName: "kiwi", cwd: "/wt/kiwi"),
      ],
      projectNames: [:]
    )

    let split = repository.loadAll().first { $0.id != original.id }
    #expect(split?.isArchived == true)
  }

  @Test("Workspace worktreeName round-trips through persistence")
  func worktreeNameRoundTrip() throws {
    let original = workspace(
      rootDirectory: "/wt/kiwi", worktreeName: "kiwi", chatIds: [UUID()]
    )
    let decoded = try JSONDecoder().decode(
      Workspace.self, from: JSONEncoder().encode(original)
    )
    #expect(decoded.worktreeName == "kiwi")

    // Payloads written before the field existed decode as nil.
    var json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
    )
    json["worktreeName"] = nil
    let legacy = try JSONDecoder().decode(
      Workspace.self, from: JSONSerialization.data(withJSONObject: json)
    )
    #expect(legacy.worktreeName == nil)
  }

  @Test("Migration markers persist across repository instances")
  func markerPersists() {
    let store = InMemoryStore()
    let repository = DefaultWorkspaceRepository(store: store)
    #expect(!repository.hasPerformedMigration("test-key"))
    repository.markMigrationPerformed("test-key")
    #expect(repository.hasPerformedMigration("test-key"))
    #expect(DefaultWorkspaceRepository(store: store).hasPerformedMigration("test-key"))
  }
}

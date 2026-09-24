import Foundation
import Testing

@testable import CodevisorCore

@Suite("Client-only archive repair revert")
struct ClientOnlyArchiveRepairRevertTests {
  private func workspace(
    serverId: String = "local", isArchived: Bool, isServerSynced: Bool
  ) -> Workspace {
    Workspace(
      name: "Work",
      rootDirectory: "/tmp/work",
      serverId: serverId,
      projectId: UUID(),
      centerTabs: [WorkspaceTab(root: .leaf(PaneGroupState()))],
      isArchived: isArchived,
      isServerSynced: isServerSynced
    )
  }

  /// A store the bad repair already ran on, with its first sync to `local`.
  private func affectedRepository() -> DefaultWorkspaceRepository {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    repository.markMigrationPerformed(ClientOnlyArchiveRepairRevert.revertedRepairKey)
    repository.markMigrationPerformed("persisted-navigation-v1:local")
    return repository
  }

  @Test("Hides the local-only workspaces the bad repair resurfaced")
  func hidesResurfacedWorkspaces() {
    let repository = affectedRepository()
    let resurfaced = workspace(isArchived: false, isServerSynced: false)
    let real = workspace(isArchived: false, isServerSynced: true)
    let archived = workspace(isArchived: true, isServerSynced: true)
    repository.save(resurfaced)
    repository.save(real)
    repository.save(archived)

    #expect(ClientOnlyArchiveRepairRevert.runIfNeeded(workspaces: repository))

    #expect(repository.workspace(id: resurfaced.id)?.isArchived == true)
    // Workspaces the server knows are the real sidebar; they stay as they were.
    #expect(repository.workspace(id: real.id)?.isArchived == false)
    #expect(repository.workspace(id: archived.id)?.isArchived == true)
  }

  @Test("Does nothing on a store the bad repair never ran on")
  func leavesUnaffectedStoresAlone() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    repository.markMigrationPerformed("persisted-navigation-v1:local")
    // Unsynced and visible, but nothing resurfaced it: a genuine workspace.
    let visible = workspace(isArchived: false, isServerSynced: false)
    repository.save(visible)

    #expect(ClientOnlyArchiveRepairRevert.runIfNeeded(workspaces: repository))

    #expect(repository.workspace(id: visible.id)?.isArchived == false)
  }

  @Test("Leaves workspaces on a machine that has not finished its first sync")
  func leavesPendingPublicationAlone() {
    let repository = affectedRepository()
    // No navigation receipt for this machine yet, so an unsynced workspace
    // may simply be waiting to be published.
    let pending = workspace(serverId: "remote", isArchived: false, isServerSynced: false)
    repository.save(pending)

    ClientOnlyArchiveRepairRevert.runIfNeeded(workspaces: repository)

    #expect(repository.workspace(id: pending.id)?.isArchived == false)
  }

  @Test("Runs once, so a workspace restored afterwards stays restored")
  func runsOnce() {
    let repository = affectedRepository()
    #expect(ClientOnlyArchiveRepairRevert.runIfNeeded(workspaces: repository))

    let later = workspace(isArchived: false, isServerSynced: false)
    repository.save(later)
    #expect(!ClientOnlyArchiveRepairRevert.runIfNeeded(workspaces: repository))
    #expect(repository.workspace(id: later.id)?.isArchived == false)
  }
}

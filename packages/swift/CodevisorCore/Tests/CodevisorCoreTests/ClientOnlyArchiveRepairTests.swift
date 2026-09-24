import Foundation
import Testing

@testable import CodevisorCore

@Suite("Client-only archive repair")
struct ClientOnlyArchiveRepairTests {
  private func workspace(isArchived: Bool, isServerSynced: Bool) -> Workspace {
    Workspace(
      name: "Work",
      rootDirectory: "/tmp/work",
      serverId: "local",
      projectId: UUID(),
      centerTabs: [WorkspaceTab(root: .leaf(PaneGroupState()))],
      isArchived: isArchived,
      isServerSynced: isServerSynced
    )
  }

  @Test("A workspace archived before the server ever saw it is revealed again")
  func revealsClientOnlyArchivedWorkspaces() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let stranded = workspace(isArchived: true, isServerSynced: false)
    let confirmed = workspace(isArchived: true, isServerSynced: true)
    let live = workspace(isArchived: false, isServerSynced: false)
    repository.save(stranded)
    repository.save(confirmed)
    repository.save(live)

    #expect(ClientOnlyArchiveRepair.runIfNeeded(workspaces: repository))

    // Nothing could ever confirm the stranded one's archive, and while it sat
    // there it hid every chat in it on this machine alone.
    #expect(repository.workspace(id: stranded.id)?.isArchived == false)
    // An archive the server acknowledged is real and stays put.
    #expect(repository.workspace(id: confirmed.id)?.isArchived == true)
    #expect(repository.workspace(id: live.id)?.isArchived == false)
  }

  @Test("The repair runs once per store")
  func runsOnce() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    #expect(ClientOnlyArchiveRepair.runIfNeeded(workspaces: repository))

    // A workspace archived AFTER the repair is a fresh user action with its
    // own upload, so a second pass must not undo it.
    let later = workspace(isArchived: true, isServerSynced: false)
    repository.save(later)
    #expect(!ClientOnlyArchiveRepair.runIfNeeded(workspaces: repository))
    #expect(repository.workspace(id: later.id)?.isArchived == true)
  }
}

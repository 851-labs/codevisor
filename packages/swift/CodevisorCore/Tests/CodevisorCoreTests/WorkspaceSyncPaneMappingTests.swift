import Foundation
import Testing
@testable import CodevisorCore

/// The pane<->server-record mapping behind workspace sync: plugin panes ride
/// a `plugin:`-prefixed provider without icon metadata; unknown providers
/// still drop silently.
@MainActor
@Suite("WorkspaceSyncModel pane mapping")
struct WorkspaceSyncPaneMappingTests {
  private let workspaceId = UUID()

  @Test("First-send server acknowledgement retains the mounted chat pane", arguments: [false, true])
  func firstSendKeepsPaneIdentity(promotedDraft: Bool) throws {
    let sessionId = UUID()
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    var workspace = repository.ensureWorkspace(
      for: WorkspaceSessionSeed(
        sessionId: sessionId, initialName: "Project", serverId: "local",
        projectId: UUID(), rootDirectory: nil
      ), legacyGroups: nil
    )
    if promotedDraft {
      var group = PaneGroupState()
      let draft = group.addChatPane()
      group.assignChatSession(paneId: draft.id, sessionId: sessionId, name: "Hello")
      workspace.centerTree = .leaf(group)
    }
    let group = try #require(workspace.centerTree.allGroups.first?.state)
    let paneId = try #require(group.selectedPaneId)
    let tabId = workspace.selectedCenterTabId
    let leafId = workspace.centerTree.allGroups.first?.id
    // A new workspace's first chat is created by /open using the session
    // id. An existing draft is promoted with its already-published pane id.
    let record = ServerWorkspacePane(
      id: (promotedDraft ? paneId : sessionId).uuidString.lowercased(),
      workspaceId: workspace.id.uuidString.lowercased(), providerId: "codevisor",
      paneType: "chat", title: "Hello", resourceKind: "session",
      resourceId: sessionId.uuidString.lowercased(), createdAt: "2026-01-01T00:00:00.000Z"
    )

    WorkspaceSyncModel.reconcilePanes(in: &workspace, records: [record], protectedLocalPaneIds: [])

    #expect(workspace.selectedCenterTabId == tabId)
    #expect(workspace.centerTree.allGroups.first?.id == leafId)
    let acknowledged = try #require(workspace.centerTree.allGroups.first?.state)
    #expect(acknowledged.selectedPaneId == paneId)
    #expect(acknowledged.panes.map(\.id) == [paneId])
    #expect(acknowledged.selectedPane?.chatSessionId == sessionId)
    #expect(acknowledged.selectedPane?.name == "Hello")
  }

  @Test("Plugin panes publish a plugin-scoped provider and round-trip")
  func pluginPaneRoundTrip() {
    let id = UUID()
    let pane = PaneDescriptorState(
      id: id,
      kind: .plugin,
      name: "Git Diff",
      // Plugin panes key on their own id (there is no PTY); the
      // restored descriptor rebuilds exactly this.
      terminalKey: id.uuidString,
      pluginId: "codevisor.git-diff",
      pluginPaneType: "diff"
    )
    let record = WorkspaceSyncModel.serverPane(
      from: pane, workspaceId: workspaceId, createdAt: Date()
    )
    #expect(record.providerId == "plugin:codevisor.git-diff")
    #expect(record.paneType == "diff")
    #expect(record.title == "Git Diff")
    #expect(record.metadata == nil)
    #expect(record.resourceKind == nil)
    #expect(record.resourceId == nil)

    // The server echoes the record verbatim; the descriptor it rebuilds
    // must equal the one that was published (identical terminalKey is
    // what makes the optimistic sync barrier acknowledge the echo).
    let restored = WorkspaceSyncModel.descriptor(from: record)
    #expect(restored == pane)
  }

  @Test("Plugin panes never persist icon metadata")
  func pluginPaneOmitsMetadata() {
    let pane = PaneDescriptorState(
      id: UUID(),
      kind: .plugin,
      name: "Diff",
      terminalKey: UUID().uuidString,
      pluginId: "codevisor.git-diff",
      pluginPaneType: "diff"
    )
    let record = WorkspaceSyncModel.serverPane(
      from: pane, workspaceId: workspaceId, createdAt: Date()
    )
    #expect(record.metadata == nil)
  }

  @Test("Unknown providers and malformed plugin providers still drop silently")
  func unknownProvidersDrop() {
    func record(providerId: String, paneType: String = "diff") -> ServerWorkspacePane {
      ServerWorkspacePane(
        id: UUID().uuidString,
        workspaceId: workspaceId.uuidString,
        providerId: providerId,
        paneType: paneType,
        title: "Pane",
        createdAt: "2026-01-01T00:00:00.000Z"
      )
    }
    #expect(WorkspaceSyncModel.descriptor(from: record(providerId: "somebody-else")) == nil)
    // A bare "plugin:" carries no plugin identity.
    #expect(WorkspaceSyncModel.descriptor(from: record(providerId: "plugin:")) == nil)
    // Unknown codevisor pane types remain forward-compatible drops.
    #expect(
      WorkspaceSyncModel.descriptor(
        from: record(providerId: "codevisor", paneType: "hologram")
      ) == nil
    )
  }

  @Test("Native codevisor panes keep their existing mapping; New Tab rows are ignored")
  func codevisorPanesStillMap() {
    let id = UUID()
    func record(paneType: String, title: String) -> ServerWorkspacePane {
      ServerWorkspacePane(
        id: id.uuidString,
        workspaceId: workspaceId.uuidString,
        providerId: "codevisor",
        paneType: paneType,
        title: title,
        createdAt: "2026-01-01T00:00:00.000Z"
      )
    }
    let browser = WorkspaceSyncModel.descriptor(from: record(paneType: "browser", title: "Browser"))
    #expect(browser?.kind == .browser)
    #expect(browser?.id == id)
    // The New Tab page is device-local. A row from a client that still
    // publishes it means nothing here.
    #expect(WorkspaceSyncModel.descriptor(from: record(paneType: "new-tab", title: "New tab")) == nil)
  }
}

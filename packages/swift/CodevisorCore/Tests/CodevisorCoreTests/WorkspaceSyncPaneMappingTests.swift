import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("WorkspaceSyncModel pane mapping")
struct WorkspaceSyncPaneMappingTests {
  private let workspaceId = UUID()

  @Test("First-send server acknowledgement retains the mounted chat pane", arguments: [false, true])
  func firstSendKeepsPaneIdentity(promotedDraft: Bool) throws {
    let sessionId = UUID()
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
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
    let record = ServerWorkspacePane(
      id: (promotedDraft ? paneId : sessionId).uuidString.lowercased(),
      workspaceId: workspace.id.uuidString.lowercased(), providerId: "codevisor",
      paneType: "chat", title: "Hello", resourceKind: "session",
      resourceId: sessionId.uuidString.lowercased(), createdAt: "2026-01-01T00:00:00.000Z"
    )

    WorkspacePaneReconciler(records: [record], protectedLocalPaneIds: []).reconcile(&workspace)

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
      terminalKey: id.uuidString,
      pluginId: "codevisor.git-diff",
      pluginPaneType: "diff"
    )
    let record = ServerPaneMapping.record(
      from: pane, workspaceId: workspaceId, createdAt: Date()
    )
    #expect(record.providerId == "plugin:codevisor.git-diff")
    #expect(record.paneType == "diff")
    #expect(record.title == "Git Diff")
    #expect(record.metadata == nil)
    #expect(record.resourceKind == nil)
    #expect(record.resourceId == nil)

    let restored = ServerPaneMapping.descriptor(from: record)
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
    let record = ServerPaneMapping.record(
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
    #expect(ServerPaneMapping.descriptor(from: record(providerId: "somebody-else")) == nil)
    #expect(ServerPaneMapping.descriptor(from: record(providerId: "plugin:")) == nil)
    #expect(
      ServerPaneMapping.descriptor(
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
    let browser = ServerPaneMapping.descriptor(from: record(paneType: "browser", title: "Browser"))
    #expect(browser?.kind == .browser)
    #expect(browser?.id == id)
    #expect(ServerPaneMapping.descriptor(from: record(paneType: "new-tab", title: "New tab")) == nil)
  }

  @Test("Terminals map; the hidden agent terminals older clients published do not")
  func agentTerminalRowsAreIgnored() {
    func record(_ resourceId: String, metadata: String?) -> ServerWorkspacePane {
      ServerWorkspacePane(
        id: UUID().uuidString,
        workspaceId: workspaceId.uuidString,
        providerId: "codevisor",
        paneType: "terminal",
        title: "Terminal",
        resourceKind: "terminal",
        resourceId: resourceId,
        metadata: metadata,
        createdAt: "2026-01-01T00:00:00.000Z"
      )
    }
    let user = ServerPaneMapping.descriptor(from: record("shell", metadata: #"{"attachOnly":false}"#))
    #expect(user?.kind == .terminal)
    #expect(user?.terminalKey == "shell")
    #expect(ServerPaneMapping.descriptor(from: record("shell", metadata: nil))?.kind == .terminal)
    let agent = record("chat:bg:tool-1", metadata: #"{"attachOnly":true,"ownerChatSessionId":"\#(UUID())"}"#)
    #expect(ServerPaneMapping.descriptor(from: agent) == nil)
    let pane = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal", terminalKey: "shell")
    let published = ServerPaneMapping.record(
      from: pane, workspaceId: workspaceId, createdAt: Date(timeIntervalSince1970: 0))
    #expect(published.metadata == nil)
  }

  @Test("Review panes sync what they compare; an unknown mode falls back to branch")
  func reviewPaneRoundTrip() throws {
    let id = UUID()
    let pane = PaneDescriptorState(
      id: id, kind: .review, name: "Review", terminalKey: id.uuidString,
      review: ReviewPanePreferences(mode: .branch, base: "origin/release"))
    let record = ServerPaneMapping.record(from: pane, workspaceId: workspaceId, createdAt: Date())
    #expect(record.providerId == "codevisor")
    #expect(record.paneType == "review")
    #expect(ServerPaneMapping.descriptor(from: record) == pane)

    let future = ServerWorkspacePane(
      id: id.uuidString, workspaceId: workspaceId.uuidString, providerId: "codevisor",
      paneType: "review", title: "Review", metadata: #"{"mode":"sinceRelease","base":"v2"}"#,
      createdAt: "2026-01-01T00:00:00.000Z")
    let restored = try #require(ServerPaneMapping.descriptor(from: future))
    #expect(restored.review == ReviewPanePreferences(mode: .branch, base: "v2"))
  }

  @Test("Document rows restore from the file and legacy markdown types, and only with a file path")
  func documentRows() {
    let id = UUID()
    func record(_ paneType: String, _ resourceKind: String?, _ resourceId: String?) -> ServerWorkspacePane {
      ServerWorkspacePane(
        id: id.uuidString, workspaceId: workspaceId.uuidString, providerId: "codevisor",
        paneType: paneType, title: "Notes", resourceKind: resourceKind, resourceId: resourceId,
        createdAt: "2026-01-01T00:00:00.000Z")
    }
    let document = PaneDescriptorState(
      id: id, kind: .document, name: "Notes", terminalKey: id.uuidString, documentPath: "/notes.md")
    #expect(ServerPaneMapping.descriptor(from: record("markdown", "file", "/notes.md")) == document)
    #expect(ServerPaneMapping.descriptor(from: record("file", "file", "")) == nil)
    #expect(ServerPaneMapping.descriptor(from: record("file", "session", "/notes.md")) == nil)
  }

  @Test(
    "Device-local panes publish only their type and never restore",
    arguments: [(PaneKind.newTab, "new-tab"), (.subagent, "subagent"), (.transcript, "transcript")]
  )
  func deviceLocalPanes(kind: PaneKind, paneType: String) {
    let pane = PaneDescriptorState(
      id: UUID(), kind: kind, name: "Local", terminalKey: "local", chatSessionId: UUID(), documentPath: "/a.md")
    let record = ServerPaneMapping.record(from: pane, workspaceId: workspaceId, createdAt: Date())
    #expect(record.providerId == "codevisor")
    #expect(record.paneType == paneType)
    #expect(record.resourceKind == nil)
    #expect(record.resourceId == nil)
    #expect(record.metadata == nil)
    #expect(ServerPaneMapping.descriptor(from: record) == nil)
  }

  @Test("A plugin pane without an id or type publishes the fallback provider and type")
  func pluginPaneFallbacks() {
    let pane = PaneDescriptorState(id: UUID(), kind: .plugin, name: "Plugin", terminalKey: "plugin")
    let record = ServerPaneMapping.record(from: pane, workspaceId: workspaceId, createdAt: Date())
    #expect(record.providerId == "plugin:unknown")
    #expect(record.paneType == "pane")
    #expect(ServerPaneMapping.descriptor(from: record)?.pluginId == "unknown")
  }
}

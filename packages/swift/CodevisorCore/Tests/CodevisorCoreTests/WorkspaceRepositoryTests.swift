import Foundation
import Testing
@testable import CodevisorCore

@Suite("Workspace repository")
struct WorkspaceRepositoryTests {
  private func seed(
    sessionId: UUID = UUID(),
    initialName: String = "Example Project",
    root: String? = "/tmp/checkout"
  ) -> WorkspaceSessionSeed {
    WorkspaceSessionSeed(
      sessionId: sessionId,
      initialName: initialName,
      serverId: "local",
      projectId: UUID(),
      rootDirectory: root
    )
  }

  @Test("ensureWorkspace creates once and is idempotent")
  func ensureIdempotent() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let seed = seed()
    let first = repository.ensureWorkspace(for: seed, legacyGroups: nil)
    let second = repository.ensureWorkspace(for: seed, legacyGroups: nil)
    #expect(first.id == second.id)
    #expect(repository.loadAll().count == 1)
    #expect(repository.workspaceId(forSession: seed.sessionId) == first.id)
  }

  @Test("Promoting a New Tab replaces its pane in the same layout slot")
  func newTabPromotionKeepsLayoutIdentity() {
    var state = PaneGroupState()
    let placeholder = state.addNewTabPane()
    let tab = WorkspaceTab(root: .leaf(state))
    var workspace = Workspace(
      name: "Example",
      rootDirectory: "/tmp/example",
      serverId: "local",
      projectId: UUID(),
      centerTabs: [tab],
      bottomGroup: PaneGroupState()
    )
    let sessionId = UUID()
    let promoted = PaneDescriptorState(
      id: placeholder.id,
      kind: .chat,
      name: "New Chat",
      terminalKey: placeholder.terminalKey,
      chatSessionId: sessionId
    )

    let selectedTabId = workspace.upsertCenterPane(promoted)

    #expect(selectedTabId == tab.id)
    #expect(workspace.centerTabs.count == 1)
    #expect(workspace.centerTabs[0].root.allGroups[0].state.panes == [promoted])
    #expect(workspace.tabId(containingChat: sessionId) == tab.id)
  }

  @Test("isArchived round-trips and pre-field payloads decode as active")
  func isArchivedCodable() throws {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    var workspace = repository.ensureWorkspace(for: seed(), legacyGroups: nil)
    // Payloads written before the field existed must load as active.
    var withoutField =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(workspace)
      ) as! [String: Any]
    withoutField.removeValue(forKey: "isArchived")
    let legacyData = try JSONSerialization.data(withJSONObject: withoutField)
    let decoded = try JSONDecoder().decode(Workspace.self, from: legacyData)
    #expect(decoded.isArchived == false)
    workspace.isArchived = true
    repository.save(workspace)
    #expect(repository.workspace(id: workspace.id)?.isArchived == true)
  }

  @Test("Legacy icon metadata is ignored and no longer persisted")
  func legacyIconMetadataIsRemoved() throws {
    let workspace = DefaultWorkspaceRepository(store: InMemoryStore())
      .ensureWorkspace(for: seed(), legacyGroups: nil)
    var payload = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any]
    )
    payload["symbolName"] = "hammer"

    let decoded = try JSONDecoder().decode(
      Workspace.self,
      from: JSONSerialization.data(withJSONObject: payload)
    )
    let encoded = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
    )
    #expect(encoded["symbolName"] == nil)
  }

  @Test("Backfill adopts the workspace's initial project identity")
  func backfillIdentity() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let seed = seed()
    let workspace = repository.ensureWorkspace(for: seed, legacyGroups: nil)
    #expect(workspace.name == "Example Project")
    #expect(!workspace.hasCustomName)
    #expect(workspace.rootDirectory == "/tmp/checkout")
    #expect(workspace.chatSessionIds == [seed.sessionId])
    // The fresh tree is a single leaf holding the chat pane.
    #expect(workspace.centerTree.allGroups.count == 1)
    #expect(workspace.centerTree.groupId(containingChat: seed.sessionId) != nil)
    #expect(workspace.bottomGroup.panes.isEmpty)
  }

  @Test("Nested split leaf resolves its own selected chat")
  func nestedSplitSelectedChatSource() {
    let leftChat = UUID(), upperChat = UUID(), lowerChat = UUID()
    let leftLeaf = UUID(), upperLeaf = UUID(), lowerLeaf = UUID()
    var upper = PaneGroupState()
    let upperPane = upper.addChatPane(sessionId: upperChat)
    var lower = PaneGroupState()
    let lowerPane = lower.addChatPane(sessionId: lowerChat)
    let root = SplitNode.split(
      orientation: .horizontal,
      children: [
        SplitChild(
          fraction: 0.5,
          node: .leaf(.centerInitial(sessionId: leftChat), id: leftLeaf)
        ),
        SplitChild(
          fraction: 0.5,
          node: .split(
            orientation: .vertical,
            children: [
              SplitChild(fraction: 0.5, node: .leaf(upper, id: upperLeaf)),
              SplitChild(fraction: 0.5, node: .leaf(lower, id: lowerLeaf)),
            ])),
      ])
    let tab = WorkspaceTab(root: root, activeLeafId: lowerLeaf)
    let workspace = Workspace(
      name: "Nested",
      rootDirectory: "/tmp/project",
      serverId: "local",
      projectId: UUID(),
      centerTabs: [tab],
      bottomGroup: .initial(sessionId: leftChat)
    )

    #expect(workspace.selectedPane(inLeaf: upperLeaf)?.id == upperPane.id)
    #expect(workspace.selectedPane(inLeaf: lowerLeaf)?.id == lowerPane.id)
    #expect(workspace.pane(containingChat: upperChat)?.id == upperPane.id)
    #expect(workspace.pane(containingChat: lowerChat)?.id == lowerPane.id)
    #expect(workspace.selectedPane(inLeaf: UUID()) == nil)
  }

  @Test("Backfill migrates legacy per-session pane groups")
  func backfillMigratesLegacyGroups() {
    let store = InMemoryStore()
    let legacy = DefaultPaneGroupRepository(store: store)
    let sessionId = UUID()
    var center = PaneGroupState.centerInitial(sessionId: sessionId)
    center.addTerminalPane(sessionId: sessionId)
    legacy.save(center, sessionId: sessionId, placement: .center)
    var bottom = PaneGroupState.initial(sessionId: sessionId)
    bottom.addTerminalPane(sessionId: sessionId)
    legacy.save(bottom, sessionId: sessionId, placement: .bottom)

    let repository = DefaultWorkspaceRepository(store: store)
    let workspace = repository.ensureWorkspace(
      for: seed(sessionId: sessionId),
      legacyGroups: legacy
    )
    // The legacy group's selected terminal remains the visible-layout
    // tab; its hidden chat is lifted into its own top tab and learns its
    // session reference during migration.
    #expect(workspace.centerTabs.count == 2)
    #expect(
      workspace.centerTabs.allSatisfy {
        $0.root.allGroups.allSatisfy { $0.state.panes.count == 1 }
      })
    #expect(workspace.chatSessionIds == [sessionId])
    #expect(workspace.bottomGroup.panes.count == 2)
  }

  @Test("Version-1 split groups invert into layout tabs without losing panes")
  func legacyWorkspaceInversion() throws {
    let chatSession = UUID()
    var left = PaneGroupState.centerInitial(sessionId: chatSession)
    let selectedTerminal = left.addTerminalPane(sessionId: chatSession)
    var right = PaneGroupState()
    let firstRight = right.addTerminalPane(sessionId: chatSession)
    let selectedRight = right.addTerminalPane(sessionId: chatSession)
    let leftId = UUID(), rightId = UUID()
    let legacyTree = SplitNode.split(
      orientation: .horizontal,
      children: [
        SplitChild(fraction: 0.35, node: .leaf(left, id: leftId)),
        SplitChild(fraction: 0.65, node: .leaf(right, id: rightId)),
      ])

    let fresh = Workspace(
      name: "Legacy", rootDirectory: "/tmp", serverId: "local", projectId: UUID(),
      centerTree: .leaf(.centerInitial(sessionId: chatSession)),
      bottomGroup: .initial(sessionId: chatSession)
    )
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as! [String: Any]
    json.removeValue(forKey: "centerTabs")
    json.removeValue(forKey: "selectedCenterTabId")
    json["centerTree"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyTree))

    let decoded = try JSONDecoder().decode(
      Workspace.self,
      from: JSONSerialization.data(withJSONObject: json)
    )
    #expect(decoded.centerTabs.count == 3)
    #expect(decoded.centerTabs[0].root.allGroups.map(\.id) == [leftId, rightId])
    #expect(
      decoded.centerTabs[0].root.allGroups.map { $0.state.panes[0].id }
        == [selectedTerminal.id, selectedRight.id])
    #expect(decoded.centerTabs[1].root.allGroups[0].state.panes[0].chatSessionId == chatSession)
    #expect(decoded.centerTabs[2].root.allGroups[0].state.panes[0].id == firstRight.id)
    #expect(
      decoded.centerTabs.flatMap { $0.root.allGroups }.allSatisfy {
        $0.state.panes.count == 1
      })
  }

  @Test("A version-2 workspace with no tabs repairs to a layout-only shell")
  func emptyTopTabsRepairOnDecode() throws {
    let fresh = Workspace(
      name: "Empty", rootDirectory: "/tmp/project", serverId: "local",
      projectId: UUID(), centerTree: .leaf(.centerInitial(sessionId: UUID())),
      bottomGroup: .initial(sessionId: UUID())
    )
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as! [String: Any]
    json["centerTabs"] = []
    json["selectedCenterTabId"] = UUID().uuidString

    let decoded = try JSONDecoder().decode(
      Workspace.self,
      from: JSONSerialization.data(withJSONObject: json)
    )
    #expect(decoded.centerTabs.count == 1)
    #expect(decoded.selectedCenterTabId == decoded.centerTabs[0].id)
    #expect(decoded.centerTabs[0].root.allGroups[0].state.panes.isEmpty)
  }

  @Test("Workspace tab custom titles persist and older tabs remain automatic")
  func workspaceTabCustomTitlePersistence() throws {
    let tab = WorkspaceTab(
      customTitle: "Pinned Layout",
      root: .leaf(.centerInitial(sessionId: UUID()))
    )
    let encoded = try JSONEncoder().encode(tab)
    let decoded = try JSONDecoder().decode(WorkspaceTab.self, from: encoded)
    #expect(decoded.customTitle == "Pinned Layout")
    #expect(decoded.root == tab.root)
    #expect(decoded.activeLeafId == tab.activeLeafId)

    var legacyJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    legacyJSON.removeValue(forKey: "customTitle")
    let legacy = try JSONDecoder().decode(
      WorkspaceTab.self,
      from: JSONSerialization.data(withJSONObject: legacyJSON)
    )
    #expect(legacy.customTitle == nil)
  }

  @Test("Automatic names follow new worktrees but explicit names stay pinned")
  func automaticNameUpdates() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let sessionId = UUID()
    let created = repository.ensureWorkspace(
      for: seed(sessionId: sessionId, initialName: "Example Project"),
      legacyGroups: nil
    )
    // Merely rendering a chat with another suggested initial name does not
    // change an established workspace identity.
    let ensured = repository.ensureWorkspace(
      for: seed(sessionId: sessionId, initialName: "Another Project"),
      legacyGroups: nil
    )
    #expect(ensured.name == "Example Project")

    repository.setAutomaticName("rowland", forWorkspace: created.id)
    #expect(repository.workspace(id: created.id)?.name == "rowland")

    var pinned = repository.workspace(id: created.id)!
    pinned.name = "My workspace"
    pinned.hasCustomName = true
    repository.save(pinned)
    repository.setAutomaticName("newton", forWorkspace: created.id)
    #expect(repository.workspace(id: created.id)?.name == "My workspace")
  }

  @Test("Workspace-backed group repository round-trips both placements")
  func workspaceGroupRepository() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let sessionId = UUID()
    let workspace = repository.ensureWorkspace(for: seed(sessionId: sessionId), legacyGroups: nil)
    let groupId = workspace.centerTree.groupId(containingChat: sessionId)
    let bridge = WorkspacePaneGroupRepository(
      workspaceId: workspace.id,
      groupId: groupId,
      repository: repository
    )

    var center = bridge.load(sessionId: sessionId, placement: .center)
    #expect(center?.panes.first?.kind == .chat)
    center?.panes[0].name = "Renamed Chat"
    bridge.save(center!, sessionId: sessionId, placement: .center)
    #expect(bridge.load(sessionId: sessionId, placement: .center)?.panes[0].name == "Renamed Chat")
    #expect(repository.workspace(id: workspace.id)?.centerTree.allGroups[0].state.panes.count == 1)

    var bottom = bridge.load(sessionId: sessionId, placement: .bottom)!
    bottom.setHeight(300)
    bridge.save(bottom, sessionId: sessionId, placement: .bottom)
    #expect(repository.workspace(id: workspace.id)?.bottomGroup.height == 300)
  }

  @Test("Deleting a workspace clears its session index entries")
  func deleteClearsIndex() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let seed = seed()
    let workspace = repository.ensureWorkspace(for: seed, legacyGroups: nil)
    repository.delete(id: workspace.id)
    #expect(repository.loadAll().isEmpty)
    #expect(repository.workspaceId(forSession: seed.sessionId) == nil)
  }

  @Test("Persistence survives a fresh repository instance")
  func persistenceRoundTrip() {
    let store = InMemoryStore()
    let seed = seed()
    let created = DefaultWorkspaceRepository(store: store)
      .ensureWorkspace(for: seed, legacyGroups: nil)
    let reloaded = DefaultWorkspaceRepository(store: store)
    #expect(reloaded.workspace(id: created.id) == created)
    #expect(reloaded.workspaceId(forSession: seed.sessionId) == created.id)
  }

  @Test("Closed chats keep routing to their workspace (the index only grows)")
  func indexSurvivesClosedChats() {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let seed = seed()
    var workspace = repository.ensureWorkspace(for: seed, legacyGroups: nil)

    // Close the chat's tab (its pane leaves the tree; the session is
    // archived elsewhere) — the session must still resolve to this
    // workspace, or ensureWorkspace would mint a duplicate.
    let chatGroupId = workspace.centerTree.allGroups[0].id
    workspace.centerTree = workspace.centerTree.updatingGroup(id: chatGroupId) { state in
      var state = state
      state.panes.removeAll()
      return state
    }
    repository.save(workspace)

    #expect(repository.workspaceId(forSession: seed.sessionId) == workspace.id)
    let ensured = repository.ensureWorkspace(for: seed, legacyGroups: nil)
    #expect(ensured.id == workspace.id)
    #expect(repository.loadAll().count == 1)
  }

  @Test("Loading heals empty groups left by an interrupted drop")
  func loadHealsEmptyGroups() {
    let store = InMemoryStore()
    let seed = seed()
    var workspace = DefaultWorkspaceRepository(store: store)
      .ensureWorkspace(for: seed, legacyGroups: nil)
    // Persist the stale shape directly: the chat leaf sharing a split
    // with a group that never received its pane.
    let emptyId = UUID()
    workspace.centerTree = workspace.centerTree.splitting(
      groupId: workspace.centerTree.allGroups[0].id,
      edge: .bottom,
      newGroupId: emptyId,
      newGroupState: PaneGroupState(isVisible: true)
    )
    DefaultWorkspaceRepository(store: store).save(workspace)

    let healed = DefaultWorkspaceRepository(store: store).workspace(id: workspace.id)
    #expect(healed?.centerTree.allGroups.count == 1)
    #expect(healed?.centerTree.group(id: emptyId) == nil)
  }
}

import Foundation
import Testing

@testable import CodevisorCore

/// `ProjectedWorkspaceRepository`: reads come from the navigation projection;
/// saves record only this device's layout (tabs, splits, selection); a
/// workspace the server doesn't have yet is a draft.
@MainActor
@Suite("Workspace repository")
struct WorkspaceRepositoryTests {
  private let projectId = UUID()

  private func seed(
    sessionId: UUID = UUID(),
    initialName: String = "Example Project",
    root: String? = "/tmp/checkout",
    assignedWorkspaceId: UUID? = nil
  ) -> WorkspaceSessionSeed {
    WorkspaceSessionSeed(
      sessionId: sessionId,
      initialName: initialName,
      serverId: "local",
      projectId: projectId,
      rootDirectory: root,
      assignedWorkspaceId: assignedWorkspaceId
    )
  }

  /// A server workspace holding one chat, installed from a snapshot.
  private func install(
    _ navigation: NavigationFixture, chat: UUID = UUID(), name: String = "Shared"
  ) async -> Workspace {
    let workspace = Workspace(
      name: name, rootDirectory: "/tmp/shared", serverId: "local", projectId: projectId,
      centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: chat, paneId: chat)))],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), isServerSynced: true)
    await navigation.install(
      sessions: [ChatSession(id: chat, projectId: projectId, serverId: "local")], workspaces: [workspace])
    return workspace
  }

  @Test("Reads return the projected server workspaces and their chats")
  func readsTheProjection() async throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let chat = UUID()
    let installed = await install(navigation, chat: chat)

    let workspace = try #require(repository.workspace(id: installed.id))
    #expect(repository.loadAll().map(\.id) == [installed.id])
    #expect(workspace.name == "Shared")
    #expect(workspace.rootDirectory == "/tmp/shared")
    #expect(workspace.isServerSynced)
    #expect(!workspace.isDraft)
    #expect(workspace.centerTabs == installed.centerTabs)
    #expect(repository.workspaceId(forSession: chat) == installed.id)
    #expect(repository.workspace(id: UUID()) == nil)
  }

  @Test("Saving records only the layout; server fields change only through the outbox")
  func saveWritesOnlyLayout() async throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let installed = await install(navigation)
    var edited = try #require(repository.workspace(id: installed.id))
    edited.name = "Renamed locally"
    edited.hasCustomName = true
    edited.isArchived = true
    edited.sidebarOrderRevision = 9
    let terminal = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal", terminalKey: "shell")
    let tab = WorkspaceTab(root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id)))
    edited.centerTabs.append(tab)
    edited.selectedCenterTabId = tab.id

    repository.save(edited)

    let saved = try #require(repository.workspace(id: installed.id))
    #expect(saved.name == "Shared")
    #expect(!saved.hasCustomName)
    #expect(!saved.isArchived)
    #expect(saved.sidebarOrderRevision == 0)
    #expect(saved.centerTabs == edited.centerTabs)
    #expect(saved.selectedCenterTabId == tab.id)
    let layout = try #require(navigation.store.layouts.layout(for: installed.id))
    #expect(layout.tabs == edited.centerTabs)
    #expect(layout.selectedTabId == tab.id)
    #expect(navigation.store.pendingIntents.isEmpty)
  }

  @Test("Saving a workspace the server doesn't have makes it a draft")
  func saveUnknownCreatesDraft() throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let workspace = Workspace(
      name: "Scratch", rootDirectory: "/tmp/scratch", serverId: "local", projectId: projectId,
      centerTree: .leaf(PaneGroupState.centerInitialWithoutChat()))

    repository.save(workspace)

    let saved = try #require(repository.workspace(id: workspace.id))
    #expect(saved.isDraft)
    #expect(saved.name == "Scratch")
    #expect(saved.centerTabs == workspace.centerTabs)
    #expect(navigation.store.layouts.draft(id: workspace.id)?.name == "Scratch")
    #expect(navigation.store.pendingIntents.isEmpty)
  }

  @Test("ensureWorkspace drafts once, with the chat's pane keyed by the chat's id")
  func ensureDraftsOnce() throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let chat = seed()
    let first = repository.ensureWorkspace(for: chat, legacyGroups: nil)
    // Rendering the chat with another suggested name changes nothing.
    let renamedSeed = seed(sessionId: chat.sessionId, initialName: "Another")
    let second = repository.ensureWorkspace(for: renamedSeed, legacyGroups: nil)

    #expect(first.id == second.id)
    #expect(second.name == "Example Project")
    #expect(first.isDraft)
    #expect(first.rootDirectory == "/tmp/checkout")
    #expect(first.chatSessionIds == [chat.sessionId])
    #expect(first.pane(containingChat: chat.sessionId)?.id == chat.sessionId)
    #expect(first.allPanes.count == 1)
    #expect(repository.loadAll().count == 1)
    #expect(repository.workspaceId(forSession: chat.sessionId) == first.id)
  }

  @Test("ensureWorkspace returns the workspace the server assigned the chat to")
  func ensureHonorsAssignment() async throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let chat = UUID()
    let installed = await install(navigation, chat: chat)

    #expect(repository.ensureWorkspace(for: seed(sessionId: chat), legacyGroups: nil).id == installed.id)
    let newcomer = seed(assignedWorkspaceId: installed.id)
    #expect(repository.ensureWorkspace(for: newcomer, legacyGroups: nil).id == installed.id)
    #expect(navigation.store.layouts.drafts.isEmpty)
  }

  @Test("A legacy per-session pane group seeds the draft's layout")
  func ensureUsesLegacyGroup() throws {
    let store = InMemoryStore()
    let legacy = DefaultPaneGroupRepository(store: store)
    let sessionId = UUID()
    var center = PaneGroupState.centerInitial(sessionId: sessionId)
    center.addTerminalPane(sessionId: sessionId)
    legacy.save(center, sessionId: sessionId)

    let workspace = NavigationFixture().workspaces.ensureWorkspace(
      for: seed(sessionId: sessionId), legacyGroups: legacy)

    #expect(workspace.centerTabs.count == 1)
    #expect(workspace.centerTree.allGroups.first?.state.panes.map(\.id) == center.panes.map(\.id))
    #expect(workspace.chatSessionIds == [sessionId])
  }

  @Test("Deleting a draft discards it; deleting a server workspace only forgets this device's layout")
  func deleteDraftAndLayout() async throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let seed = seed()
    let draft = repository.ensureWorkspace(for: seed, legacyGroups: nil)
    repository.delete(id: draft.id)
    #expect(repository.workspace(id: draft.id) == nil)
    #expect(repository.workspaceId(forSession: seed.sessionId) == nil)
    #expect(navigation.store.layouts.draft(id: draft.id) == nil)

    let installed = await install(navigation)
    var layout = try #require(repository.workspace(id: installed.id))
    layout.centerTabs.append(WorkspaceTab(root: .leaf(PaneGroupState.centerInitialWithoutChat())))
    repository.save(layout)
    repository.delete(id: installed.id)
    navigation.store.rebuild()
    // Still on the server, so still listed -- with its panes laid out afresh.
    let restored = try #require(repository.workspace(id: installed.id))
    #expect(restored.isServerSynced)
    #expect(restored.centerTabs.count == 1)
    #expect(restored.chatSessionIds == installed.chatSessionIds)
  }

  @Test("Automatic names rename drafts locally and server workspaces through the outbox; custom names stay")
  func automaticNameUpdates() async throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let draft = repository.ensureWorkspace(for: seed(), legacyGroups: nil)
    repository.setAutomaticName("rowland", forWorkspace: draft.id)
    #expect(repository.workspace(id: draft.id)?.name == "rowland")
    #expect(navigation.store.pendingIntents.isEmpty)

    let installed = await install(navigation)
    repository.setAutomaticName(" newton ", forWorkspace: installed.id)
    #expect(repository.workspace(id: installed.id)?.name == "newton")
    #expect(
      navigation.store.pendingIntents.map(\.intent) == [
        .renameWorkspace(workspaceId: installed.id, name: "newton", hasCustomName: false)
      ])

    let pinned = NavigationFixture()
    var record = WorkspaceSyncModel.serverWorkspace(from: installed)
    record.name = "My workspace"
    record.hasCustomName = true
    await pinned.store.replace(
      ServerNavigationSnapshot(eventCursor: 1, projects: [], sessions: [], workspaces: [record], panes: []),
      machineId: "local", requestedAt: Date())
    pinned.workspaces.setAutomaticName("newton", forWorkspace: installed.id)
    #expect(pinned.workspaces.workspace(id: installed.id)?.name == "My workspace")
    #expect(pinned.store.pendingIntents.isEmpty)
  }

  @Test("Workspace-backed group repository round-trips its leaf")
  func workspaceGroupRepository() throws {
    let repository = NavigationFixture().workspaces
    let sessionId = UUID()
    let workspace = repository.ensureWorkspace(for: seed(sessionId: sessionId), legacyGroups: nil)
    let groupId = workspace.centerTree.groupId(containingChat: sessionId)
    let bridge = WorkspacePaneGroupRepository(workspaceId: workspace.id, groupId: groupId, repository: repository)

    var center = try #require(bridge.load(sessionId: sessionId))
    #expect(center.panes.first?.kind == .chat)
    center.panes[0].name = "Renamed Chat"
    bridge.save(center, sessionId: sessionId)
    #expect(bridge.load(sessionId: sessionId)?.panes[0].name == "Renamed Chat")
    #expect(repository.workspace(id: workspace.id)?.centerTree.allGroups[0].state.panes.count == 1)
  }

  @Test("Layouts and drafts survive a relaunch")
  func persistenceRoundTrip() async throws {
    let persistence = InMemoryStore()
    let first = NavigationFixture(persistence: persistence)
    let installed = await install(first)
    var layout = try #require(first.workspaces.workspace(id: installed.id))
    layout.centerTabs.append(WorkspaceTab(root: .leaf(PaneGroupState.centerInitialWithoutChat())))
    first.workspaces.save(layout)
    let seed = seed()
    let draft = first.workspaces.ensureWorkspace(for: seed, legacyGroups: nil)
    PersistenceEncoding.drain()

    let reloaded = NavigationFixture(persistence: persistence).workspaces
    #expect(reloaded.workspace(id: installed.id)?.centerTabs == layout.centerTabs)
    #expect(reloaded.workspace(id: draft.id)?.isDraft == true)
    #expect(reloaded.workspaceId(forSession: seed.sessionId) == draft.id)
    #expect(reloaded.workspaceId(forSession: installed.chatSessionIds[0]) == installed.id)
  }

  @Test("Closed chats keep routing to their workspace")
  func indexSurvivesClosedChats() async throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let chat = UUID()
    let installed = await install(navigation, chat: chat)
    // Closing the chat's tab removes its pane; the server still assigns the
    // chat to this workspace, so it must not get a second one.
    var workspace = try #require(repository.workspace(id: installed.id))
    workspace.centerTabs = [.placeholder()]
    workspace.selectedCenterTabId = workspace.centerTabs[0].id
    repository.save(workspace)
    _ = await navigation.store.apply(
      .fixture(cursor: 2, deleted: [("workspace_panes", chat.uuidString)]), machineId: "local")

    #expect(repository.workspace(id: installed.id)?.chatSessionIds.isEmpty == true)
    #expect(repository.workspaceId(forSession: chat) == installed.id)
    #expect(repository.ensureWorkspace(for: seed(sessionId: chat), legacyGroups: nil).id == installed.id)
    #expect(repository.loadAll().count == 1)
  }

  @Test("Rebuilding heals empty groups left by an interrupted drop")
  func rebuildHealsEmptyGroups() async throws {
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let installed = await install(navigation)
    var workspace = try #require(repository.workspace(id: installed.id))
    let emptyId = UUID()
    workspace.centerTree = workspace.centerTree.splitting(
      groupId: workspace.centerTree.allGroups[0].id, edge: .bottom, newGroupId: emptyId,
      newGroupState: PaneGroupState())
    repository.save(workspace)

    navigation.store.rebuild()

    let healed = try #require(repository.workspace(id: installed.id))
    #expect(healed.centerTree.allGroups.count == 1)
    #expect(healed.centerTree.group(id: emptyId) == nil)
    #expect(navigation.store.layouts.layout(for: installed.id)?.tabs == healed.centerTabs)
  }

  @Test("isArchived round-trips and pre-field payloads decode as active")
  func isArchivedCodable() throws {
    var workspace = Workspace(
      name: "Example", rootDirectory: nil, serverId: "local", projectId: projectId,
      centerTree: .leaf(.centerInitial(sessionId: UUID())))
    var withoutField = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
    withoutField.removeValue(forKey: "isArchived")
    let legacy = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: withoutField))
    #expect(legacy.isArchived == false)
    workspace.isArchived = true
    #expect(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace)).isArchived)
  }

  @Test("Legacy icon metadata is ignored and no longer persisted")
  func legacyIconMetadataIsRemoved() throws {
    let workspace = Workspace(
      name: "Example", rootDirectory: nil, serverId: "local", projectId: projectId,
      centerTree: .leaf(.centerInitial(sessionId: UUID())))
    var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
    payload["symbolName"] = "hammer"
    let decoded = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: payload))
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
    #expect(encoded["symbolName"] == nil)
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
      centerTabs: [tab]
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
      centerTabs: [tab]
    )

    #expect(workspace.selectedPane(inLeaf: upperLeaf)?.id == upperPane.id)
    #expect(workspace.selectedPane(inLeaf: lowerLeaf)?.id == lowerPane.id)
    #expect(workspace.pane(containingChat: upperChat)?.id == upperPane.id)
    #expect(workspace.pane(containingChat: lowerChat)?.id == lowerPane.id)
    #expect(workspace.selectedPane(inLeaf: UUID()) == nil)
  }

  @Test("A version-2 workspace with no tabs repairs to a local New Tab page")
  func emptyTopTabsRepairOnDecode() throws {
    let fresh = Workspace(
      name: "Empty", rootDirectory: "/tmp/project", serverId: "local",
      projectId: UUID(), centerTree: .leaf(.centerInitial(sessionId: UUID()))
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
    #expect(decoded.centerTabs[0].isPlaceholder)
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

}

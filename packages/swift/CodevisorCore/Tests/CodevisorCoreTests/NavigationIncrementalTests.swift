import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

/// Rebuilds recompute only what changed, and a view of one workspace hears
/// only about that workspace.
@MainActor
struct NavigationIncrementalTests {
  let project = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "m")

  func workspace(_ name: String, chat: ChatSession) -> Workspace {
    Workspace(
      name: name, rootDirectory: "/src/app", serverId: "m", projectId: project.id,
      centerTree: .leaf(.centerInitial(sessionId: chat.id, paneId: chat.id)), isServerSynced: true)
  }

  func installTwo() async -> (NavigationFixture, Workspace, Workspace, ChatSession, ChatSession) {
    let first = ChatSession(projectId: project.id, serverId: "m", title: "One")
    let second = ChatSession(projectId: project.id, serverId: "m", title: "Two")
    let alpha = workspace("Alpha", chat: first)
    let beta = workspace("Beta", chat: second)
    let fixture = NavigationFixture()
    await fixture.install(machineId: "m", projects: [project], sessions: [first, second], workspaces: [alpha, beta])
    return (fixture, alpha, beta, first, second)
  }

  @Test("Rebuilding with nothing changed gives the same workspaces and touches no view")
  func stableRebuild() async {
    let (fixture, alpha, beta, _, _) = await installTwo()
    let entry = fixture.store.workspaceEntries.entry(alpha.id)
    let before = fixture.workspaces.loadAll()
    let generation = entry.generation
    fixture.store.rebuild()
    fixture.store.rebuild()
    #expect(fixture.workspaces.loadAll() == before)
    #expect(entry.generation == generation)
    #expect(fixture.store.workspaceEntries.entry(beta.id).workspace?.name == "Beta")
  }

  @Test("Another workspace's change leaves this workspace's entry alone")
  func unrelatedChange() async {
    let (fixture, alpha, beta, _, _) = await installTwo()
    let alphaEntry = fixture.store.workspaceEntries.entry(alpha.id)
    let betaEntry = fixture.store.workspaceEntries.entry(beta.id)
    let alphaGeneration = alphaEntry.generation
    fixture.store.enqueue(.renameWorkspace(workspaceId: beta.id, name: "Renamed", hasCustomName: true), machineId: "m")
    #expect(betaEntry.workspace?.name == "Renamed")
    #expect(alphaEntry.generation == alphaGeneration)
  }

  @Test("Marking a chat read changes no workspace entry")
  func markReadTouchesNoWorkspace() async {
    let (fixture, alpha, beta, first, _) = await installTwo()
    let generations = [alpha.id, beta.id].map { fixture.store.workspaceEntries.entry($0).generation }
    fixture.store.enqueue(.markSessionRead(sessionId: first.id, throughSequence: 0), machineId: "m")
    #expect([alpha.id, beta.id].map { fixture.store.workspaceEntries.entry($0).generation } == generations)
  }

  @Test("A layout save updates its workspace's entry at once, and the next rebuild agrees")
  func saveUpdatesEntry() async throws {
    let (fixture, alpha, _, _, _) = await installTwo()
    let entry = fixture.store.workspaceEntries.entry(alpha.id)
    var edited = try #require(fixture.workspaces.workspace(id: alpha.id))
    let terminal = PaneDescriptorState(id: UUID(), kind: .newTab, name: "New Tab", terminalKey: "t")
    edited.upsertCenterPane(terminal)
    fixture.workspaces.save(edited)
    #expect(entry.workspace?.centerTabs.count == 2)
    fixture.store.rebuild()
    #expect(fixture.workspaces.workspace(id: alpha.id)?.centerTabs.count == 2)
  }

  @Test("A pane deleted elsewhere updates only the workspace that had it")
  func paneDeltaIsLocal() async {
    let (fixture, alpha, beta, _, _) = await installTwo()
    let alphaEntry = fixture.store.workspaceEntries.entry(alpha.id)
    let betaEntry = fixture.store.workspaceEntries.entry(beta.id)
    let alphaGeneration = alphaEntry.generation
    let betaPane = beta.allPanes[0].id
    #expect(
      await fixture.store.apply(
        .fixture(cursor: 5, deleted: [(table: "workspace_panes", id: betaPane.uuidString)]), machineId: "m"))
    #expect(betaEntry.workspace?.allPanes.contains { $0.id == betaPane } == false)
    #expect(alphaEntry.generation == alphaGeneration)
  }

  @Test("A workspace that goes away clears its entry")
  func removedWorkspaceClearsEntry() async {
    let (fixture, alpha, beta, first, second) = await installTwo()
    let betaEntry = fixture.store.workspaceEntries.entry(beta.id)
    await fixture.install(
      machineId: "m", projects: [project], sessions: [first, second], workspaces: [alpha], cursor: 9)
    #expect(betaEntry.workspace == nil)
  }

  @Test("The attention diff reports exactly the chats that changed")
  func attentionDiff() {
    let list = ProjectListModel()
    var transitions: [UUID] = []
    list.onAttentionTransition = { transitions.append($0.sessionId) }
    let quiet = ChatSession(projectId: UUID(), serverId: "m", title: "Quiet")
    var busy = ChatSession(projectId: UUID(), serverId: "m", title: "Busy")
    list.applyProjection(projects: [], sessions: [quiet, busy], origin: .snapshot)
    transitions = []
    busy.unreadCount = 3
    busy.latestAttentionSequence = 3
    list.applyProjection(projects: [], sessions: [quiet, busy], origin: .liveEvent)
    #expect(transitions == [busy.id])
    #expect(list.session(busy.id, serverId: "m")?.unreadCount == 3)
  }

  @Test("The sidebar lists live workspaces, and a chat-less workspace routes through its closed chat")
  func sidebarList() async throws {
    let open = ChatSession(projectId: project.id, serverId: "m", title: "Open")
    let closed = ChatSession(projectId: project.id, serverId: "m", title: "Closed")
    let live = workspace("Live", chat: open)
    var archived = workspace("Archived", chat: ChatSession(projectId: project.id, serverId: "m", title: "Old"))
    archived.isArchived = true
    let terminalOnly = Workspace(
      name: "Terminal", rootDirectory: "/src/app", serverId: "m", projectId: project.id,
      centerTree: .leaf(
        PaneGroupState(panes: [
          PaneDescriptorState(id: UUID(), kind: .terminal, name: "Shell", terminalKey: "shell")
        ])), isServerSynced: true)
    let fixture = NavigationFixture()
    await fixture.install(
      machineId: "m", projects: [project], sessions: [open], workspaces: [live, archived, terminalOnly])
    // The closed chat still belongs to the terminal workspace on the server.
    var closedRecord = serverSession(from: closed)
    closedRecord.workspaceId = terminalOnly.id.uuidString
    #expect(await fixture.store.apply(.fixture(cursor: 5, sessions: [closedRecord]), machineId: "m"))

    let sidebar = Dictionary(uniqueKeysWithValues: fixture.store.workspaceEntries.sidebar.map { ($0.id, $0) })
    #expect(Set(sidebar.keys) == [terminalOnly.id, live.id])
    #expect(sidebar[terminalOnly.id]?.routingChatIds == [closed.id])
    #expect(sidebar[live.id]?.routingChatIds == [open.id])
  }

  @Test("An unrelated change leaves the sidebar list as it was")
  func sidebarStable() async {
    let (fixture, _, _, first, _) = await installTwo()
    let sidebar = fixture.store.workspaceEntries.sidebar
    fixture.store.enqueue(.markSessionRead(sessionId: first.id, throughSequence: 0), machineId: "m")
    #expect(fixture.store.workspaceEntries.sidebar == sidebar)
    #expect(sidebar.count == 2)
  }
}

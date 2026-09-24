import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct SessionRenameSyncTests {
  @Test("Single-tab and split-chat rename commands update the shared title", arguments: [false, true])
  func renamesSharedChat(explicitChat: Bool) async throws {
    let fixture = await ChatRenameFixture.make()
    let tab = fixture.workspace.centerTabs[0]
    fixture.navigation.connect(fixture.fake)
    fixture.sync.renameTab(
      workspaceId: fixture.workspace.id, tabId: tab.id,
      chatSessionId: explicitChat ? fixture.chat.id : nil, to: "  Shared title  "
    )
    // Shown at once, and still shown after the server accepted it while
    // this device's cache hasn't caught up with the server's journal.
    #expect(fixture.title == "Shared title")
    fixture.fake.emit(kind: "test.journal", subjectId: "")
    await fixture.navigation.flush()
    #expect(fixture.fake.sessionRenameNames == ["Shared title"])
    #expect(fixture.fake.sessions.first?.title == "Shared title")
    #expect(fixture.title == "Shared title")
    #expect(!fixture.navigation.store.pendingIntents.isEmpty)
    await fixture.navigation.refresh(from: fixture.fake)
    #expect(fixture.title == "Shared title")
    #expect(fixture.navigation.store.pendingIntents.isEmpty)
    let updated = try #require(fixture.repository.workspace(id: fixture.workspace.id)?.centerTabs.first)
    #expect(updated.customTitle == nil)
    #expect(updated.root == tab.root)

    // A second client receives the authoritative event with its own stale
    // tab alias still on disk. That alias must not hide the shared title.
    let reader = NavigationFixture()
    await reader.install(projects: [fixture.project], sessions: [fixture.chat], workspaces: [fixture.workspace])
    var renamed = fixture.chat
    renamed.title = "Shared title"
    await reader.applyEvent(sessions: [renamed])
    let readerTab = try #require(reader.workspaces.workspace(id: fixture.workspace.id)?.centerTabs.first)
    #expect(readerTab.customTitle == "Old local alias")
    #expect(
      readerTab.displayTitle(
        for: readerTab.root.allGroups[0].state.selectedPane, chatTitle: reader.session(fixture.chat.id)?.title)
        == "Shared title")
  }

  @Test("A chat rename the server refuses drops, and the server's title shows")
  func refusedRename() async {
    let fixture = await ChatRenameFixture.make()
    fixture.fake.sessionRenameHandler = { _ in
      throw CodevisorServerClientError.httpStatus(422, "Invalid title")
    }
    fixture.navigation.connect(fixture.fake)
    fixture.model.renameSession(fixture.chat, to: "New title")
    #expect(fixture.title == "New title")
    await fixture.navigation.flush()
    #expect(fixture.navigation.store.pendingIntents.isEmpty)
    #expect(fixture.title == fixture.chat.title)
  }

  @Test("A chat rename that can't reach its machine stays shown and is sent again", arguments: [false, true])
  func unreachableRename(lostAcknowledgement: Bool) async {
    let fixture = await ChatRenameFixture.make()
    let fake = fixture.fake
    fake.sessionRenameHandler = { chat in
      if lostAcknowledgement {
        var saved = fake.sessions[0]
        saved.title = chat.title
        fake.setSessions([saved])
      }
      throw URLError(.networkConnectionLost)
    }
    fixture.navigation.connect(fake)
    fixture.model.renameSession(fixture.chat, to: "New title")
    await fixture.navigation.flush()
    #expect(fixture.title == "New title")
    #expect(fixture.navigation.store.pendingIntents.count == 1)

    // The machine is back: resending is safe even if the first one landed.
    fake.sessionRenameHandler = nil
    await fixture.navigation.sync(with: fake)
    #expect(fake.sessionRenameNames == ["New title", "New title"])
    #expect(fixture.title == "New title")
    #expect(fixture.navigation.store.pendingIntents.isEmpty)
  }

  @Test("Chat writes stay ordered while pending names coalesce")
  func rapidRenames() async {
    let fixture = await ChatRenameFixture.make()
    let started = TestSignal()
    let release = TestSignal()
    fixture.fake.sessionRenameHandler = { chat in
      if chat.title == "First" { started.signal(); await release.wait() }
    }
    defer { release.signal() }
    fixture.navigation.connect(fixture.fake)
    fixture.model.renameSession(fixture.chat, to: "First")
    await started.wait()
    #expect(fixture.title == "First")
    fixture.model.renameSession(fixture.chat, to: "Intermediate")
    fixture.model.renameSession(fixture.chat, to: "Latest")
    #expect(fixture.title == "Latest")
    #expect(fixture.fake.sessionRenameNames == ["First"])
    release.signal()
    await fixture.navigation.flush()
    #expect(fixture.fake.sessionRenameNames == ["First", "Latest"])
    await fixture.navigation.refresh(from: fixture.fake)
    #expect(fixture.title == "Latest")
  }

  @Test("An offline chat rename shows at once and waits to be sent")
  func offlineRename() async {
    let fixture = await ChatRenameFixture.make()
    fixture.model.renameSession(fixture.chat, to: "Offline")
    #expect(fixture.title == "Offline")
    #expect(fixture.navigation.store.pendingIntents.count == 1)
    #expect(fixture.fake.sessionRenameNames.isEmpty)

    fixture.navigation.connect(fixture.fake)
    await fixture.navigation.flush()
    #expect(fixture.fake.sessionRenameNames == ["Offline"])
  }

  @Test("Empty chat names are ignored and non-chat layout labels still work")
  func nearbyTabBehavior() async {
    let fixture = await ChatRenameFixture.make()
    let id = fixture.workspace.id
    let tabId = fixture.workspace.centerTabs[0].id
    fixture.sync.renameTab(workspaceId: id, tabId: tabId, to: "  ")
    #expect(fixture.navigation.store.pendingIntents.isEmpty)
    #expect(fixture.repository.workspace(id: id)?.centerTabs.first?.customTitle == "Old local alias")
    var terminal = fixture.workspace
    let pane = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal", terminalKey: "test")
    terminal.centerTabs[0].root = .leaf(PaneGroupState(panes: [pane], selectedPaneId: pane.id))
    terminal.centerTabs[0].activeLeafId = terminal.centerTabs[0].root.allGroups[0].id
    fixture.repository.save(terminal)
    fixture.sync.renameTab(workspaceId: id, tabId: tabId, to: "Logs")
    #expect(fixture.repository.workspace(id: id)?.centerTabs.first?.customTitle == "Logs")
    #expect(fixture.navigation.store.pendingIntents.isEmpty)
  }
}

@MainActor
private struct ChatRenameFixture {
  let project: Project
  let chat: ChatSession
  let workspace: Workspace
  let fake: SyncFakeServerClient
  let navigation: NavigationFixture

  var model: ProjectListModel { navigation.projectList }
  var repository: ProjectedWorkspaceRepository { navigation.workspaces }
  var sync: WorkspaceSyncModel { navigation.workspaceSync }
  var title: String? { navigation.session(chat.id)?.title }

  static func make() async -> ChatRenameFixture {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let project = Project(name: "Project", createdAt: date)
    let chat = ChatSession(projectId: project.id, harnessId: "codex", title: "Original", createdAt: date)
    let workspace = Workspace(
      name: "Workspace", rootDirectory: nil, serverId: chat.serverId, projectId: project.id,
      centerTabs: [WorkspaceTab(customTitle: "Old local alias", root: .leaf(.centerInitial(sessionId: chat.id)))],
      createdAt: date, isServerSynced: true
    )
    let server = ServerNavigationSnapshot.fixture(projects: [project], sessions: [chat], workspaces: [workspace])
    let fake = SyncFakeServerClient(
      projects: server.projects, sessions: server.sessions, workspaces: server.workspaces, panes: server.panes)
    let navigation = NavigationFixture()
    // Cursor 0 is where the fake's journal starts.
    await navigation.install(projects: [project], sessions: [chat], workspaces: [workspace], cursor: 0)
    return ChatRenameFixture(project: project, chat: chat, workspace: workspace, fake: fake, navigation: navigation)
  }
}

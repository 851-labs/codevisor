import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct SessionRenameSyncTests {
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

  @Test("Keeping a preview tab clears its preview flag and leaves other tabs alone")
  func keepsPreviewTab() async {
    let fixture = await ChatRenameFixture.make()
    let id = fixture.workspace.id
    var workspace = fixture.workspace
    workspace.centerTabs[0].isPreview = true
    fixture.repository.save(workspace)
    let tabId = workspace.centerTabs[0].id
    fixture.sync.keepTab(workspaceId: id, tabId: UUID())
    #expect(fixture.repository.workspace(id: id)?.centerTabs.first?.isPreview == true)
    fixture.sync.keepTab(workspaceId: id, tabId: tabId)
    #expect(fixture.repository.workspace(id: id)?.centerTabs.first?.isPreview == false)
    fixture.sync.keepTab(workspaceId: id, tabId: tabId)
    #expect(fixture.repository.workspace(id: id)?.centerTabs.first?.isPreview == false)
    #expect(fixture.navigation.store.pendingIntents.isEmpty)
  }
}

@MainActor
private struct ChatRenameFixture {
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
      centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: chat.id)))],
      createdAt: date, isServerSynced: true
    )
    let server = ServerNavigationSnapshot.fixture(projects: [project], sessions: [chat], workspaces: [workspace])
    let fake = SyncFakeServerClient(
      projects: server.projects, sessions: server.sessions, workspaces: server.workspaces, panes: server.panes)
    let navigation = NavigationFixture()
    await navigation.install(projects: [project], sessions: [chat], workspaces: [workspace], cursor: 0)
    return ChatRenameFixture(chat: chat, workspace: workspace, fake: fake, navigation: navigation)
  }
}

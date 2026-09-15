import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct SessionRenameSyncTests {
  @Test("Single-tab and split-chat rename commands update the shared title", arguments: [false, true])
  func renamesSharedChat(explicitChat: Bool) async throws {
    let fixture = ChatRenameFixture()
    let tab = fixture.workspace.centerTabs[0]
    await fixture.sync.renameTab(
      workspaceId: fixture.workspace.id, tabId: tab.id,
      chatSessionId: explicitChat ? fixture.chat.id : nil, to: "  Shared title  "
    )?.value

    #expect(fixture.fake.sessionRenameNames == ["Shared title"])
    #expect(fixture.fake.sessions.first?.title == "Shared title")
    #expect(fixture.model.sessions.first?.title == "Shared title")
    let updated = try #require(fixture.repository.workspace(id: fixture.workspace.id)?.centerTabs.first)
    #expect(updated.customTitle == nil)
    #expect(updated.root == tab.root)

    // A second client receives the authoritative event with its own stale
    // tab alias still on disk. That alias must not hide the shared title.
    let reader = fixture.makeModel()
    let event = ServerEventEnvelope(
      id: 1, serverId: "local", kind: "session.updated", subjectId: fixture.chat.id.uuidString,
      createdAt: "2026-06-30T00:00:00Z",
      payload: .object([
        "id": .string(fixture.chat.id.uuidString), "projectId": .string(fixture.project.id.uuidString),
        "serverId": .string("local"), "harnessId": .string("codex"), "title": .string("Shared title"),
        "origin": .string("codevisor"), "isArchived": .bool(false),
        "createdAt": .string("2026-06-30T00:00:00Z"),
      ])
    )
    _ = await reader.applyServerSessionEvent(event, serverId: fixture.chat.serverId)
    #expect(
      tab.displayTitle(for: tab.root.allGroups[0].state.selectedPane, chatTitle: reader.sessions.first?.title)
        == "Shared title")
  }

  @Test("Failed chat renames keep the authoritative title and report an error", arguments: [false, true])
  func failedRename(lostAcknowledgement: Bool) async {
    let fixture = ChatRenameFixture()
    let reporter = ErrorReporter()
    defer { reporter.dismissAll() }
    let fake = fixture.fake
    fake.sessionRenameHandler = { chat in
      if lostAcknowledgement {
        var saved = fake.sessions[0]
        saved.title = chat.title
        fake.setSessions([saved])
      }
      throw URLError(.networkConnectionLost)
    }
    defer { fake.sessionRenameHandler = nil }
    await fixture.model.renameSession(fixture.chat, to: "New title", errorReporter: reporter)?.value
    #expect(fixture.model.sessions.first?.title == (lostAcknowledgement ? "New title" : fixture.chat.title))
    #expect(reporter.entries.map(\.title) == ["Couldn't Rename Chat"])
  }

  @Test("Chat writes stay ordered while pending names coalesce")
  func rapidRenames() async {
    let fixture = ChatRenameFixture()
    let started = TestSignal()
    let release = TestSignal()
    fixture.fake.sessionRenameHandler = { chat in
      if chat.title == "First" { started.signal(); await release.wait() }
    }
    let task = fixture.model.renameSession(fixture.chat, to: "First")
    defer { release.signal(); task?.cancel() }
    await started.wait()
    #expect(fixture.model.sessions.first?.title == fixture.chat.title)
    fixture.model.renameSession(fixture.chat, to: "Intermediate")
    fixture.model.renameSession(fixture.chat, to: "Latest")
    #expect(fixture.fake.sessionRenameNames == ["First"])
    release.signal()
    await task?.value
    #expect(fixture.fake.sessionRenameNames == ["First", "Latest"])
    #expect(fixture.model.sessions.first?.title == "Latest")
  }

  @Test("No client cannot produce a saved-looking local chat rename")
  func noClient() {
    let fixture = ChatRenameFixture()
    let reporter = ErrorReporter()
    defer { reporter.dismissAll() }
    fixture.model.configureServerClientProvider { _ in nil }
    #expect(fixture.model.renameSession(fixture.chat, to: "Offline", errorReporter: reporter) == nil)
    #expect(fixture.model.sessions.first?.title == fixture.chat.title)
    #expect(reporter.entries.count == 1)
  }

  @Test("Empty chat names are ignored and non-chat layout labels still work")
  func nearbyTabBehavior() {
    let fixture = ChatRenameFixture()
    let id = fixture.workspace.id
    let tabId = fixture.workspace.centerTabs[0].id
    fixture.sync.renameTab(workspaceId: id, tabId: tabId, to: "  ")
    #expect(fixture.fake.sessionRenameNames.isEmpty)
    #expect(fixture.repository.workspace(id: id)?.centerTabs.first?.customTitle == "Old local alias")
    var terminal = fixture.workspace
    let pane = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal", terminalKey: "test")
    terminal.centerTabs[0].root = .leaf(PaneGroupState(panes: [pane], selectedPaneId: pane.id))
    terminal.centerTabs[0].activeLeafId = terminal.centerTabs[0].root.allGroups[0].id
    fixture.repository.save(terminal)
    fixture.sync.renameTab(workspaceId: id, tabId: tabId, to: "Logs")
    #expect(fixture.repository.workspace(id: id)?.centerTabs.first?.customTitle == "Logs")
    #expect(fixture.fake.sessionRenameNames.isEmpty)
  }
}

@MainActor
private struct ChatRenameFixture {
  let project: Project
  let chat: ChatSession
  let workspace: Workspace
  let fake: SyncFakeServerClient
  let model: ProjectListModel
  let repository = DefaultWorkspaceRepository(store: InMemoryStore())
  let sync: WorkspaceSyncModel

  init() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    project = Project(name: "Project", createdAt: date)
    chat = ChatSession(projectId: project.id, harnessId: "codex", title: "Original", createdAt: date)
    workspace = Workspace(
      name: "Workspace", rootDirectory: nil, serverId: chat.serverId, projectId: project.id,
      centerTabs: [WorkspaceTab(customTitle: "Old local alias", root: .leaf(.centerInitial(sessionId: chat.id)))],
      createdAt: date, isServerSynced: true
    )
    fake = SyncFakeServerClient(projects: [serverProject(from: project)], sessions: [serverSession(from: chat)])
    model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()), serverClient: fake
    )
    model.projects = [project]
    model.sessions = [chat]
    repository.save(workspace)
    sync = WorkspaceSyncModel(repository: repository, projectList: model)
  }

  func makeModel() -> ProjectListModel {
    let result = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
    result.projects = [project]
    result.sessions = [chat]
    return result
  }
}

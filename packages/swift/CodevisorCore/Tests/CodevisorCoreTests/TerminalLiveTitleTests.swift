import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

/// A terminal's live title is server-owned: it arrives on the pane record,
/// names the terminal's tab, and never becomes the name this device publishes.
@MainActor
struct TerminalLiveTitleTests {
  let project = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "m")
  let terminal = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal 1", terminalKey: "t1")

  /// A chat tab plus one terminal tab, installed as machine "m"'s snapshot.
  func installed() async -> (fixture: NavigationFixture, workspace: Workspace) {
    let chat = ChatSession(projectId: project.id, serverId: "m", title: "Fix it")
    var workspace = Workspace(
      name: "W", rootDirectory: "/src/app", serverId: "m", projectId: project.id,
      centerTree: .leaf(.centerInitial(sessionId: chat.id, paneId: chat.id)), isServerSynced: true)
    workspace.upsertCenterPane(terminal)
    let fixture = NavigationFixture()
    await fixture.install(machineId: "m", projects: [project], sessions: [chat], workspaces: [workspace])
    return (fixture, workspace)
  }

  /// The terminal's record as a `navigation.changed` event carries it.
  func record(in workspace: Workspace, liveTitle: String?) throws -> ServerWorkspacePane {
    let liveTitleField = liveTitle.map { #","liveTitle":\#(String(reflecting: $0))"# } ?? ""
    let json = """
      {"id":"\(terminal.id.uuidString.lowercased())","workspaceId":"\(workspace.id.uuidString.lowercased())",\
      "providerId":"codevisor","paneType":"terminal","title":"Terminal 1","resourceKind":"terminal",\
      "resourceId":"t1","createdAt":"2026-01-01T00:00:00.000Z"\(liveTitleField)}
      """
    return try JSONDecoder().decode(ServerWorkspacePane.self, from: Data(json.utf8))
  }

  func shownTerminal(_ fixture: NavigationFixture, _ workspace: Workspace) throws -> (WorkspaceTab, PaneDescriptorState)
  {
    let shown = try #require(fixture.workspaces.workspace(id: workspace.id))
    let tab = try #require(shown.centerTabs.first { $0.root.allGroups.first?.state.selectedPane?.id == terminal.id })
    return (tab, try #require(tab.root.allGroups.first?.state.selectedPane))
  }

  @Test("A title-only event renames the terminal's tab, and its absence restores the pane's name")
  func liveTitleEvents() async throws {
    let (fixture, workspace) = await installed()

    #expect(
      await fixture.store.apply(
        .fixture(cursor: 5, panes: [try record(in: workspace, liveTitle: "  ✳ Claude Code\n")]), machineId: "m"))
    var (tab, pane) = try shownTerminal(fixture, workspace)
    #expect(pane.name == "Terminal 1")
    #expect(tab.displayTitle(for: pane, chatTitle: nil) == "✳ Claude Code")

    // The shell exited: servers omit the field rather than sending null.
    #expect(
      await fixture.store.apply(
        .fixture(cursor: 6, panes: [try record(in: workspace, liveTitle: nil)]), machineId: "m"))
    (tab, pane) = try shownTerminal(fixture, workspace)
    #expect(pane.liveTitle == nil)
    #expect(tab.displayTitle(for: pane, chatTitle: nil) == "Terminal")
  }

  @Test("Publishing the pane sends its name, and a waiting publish keeps showing the live title")
  func publishKeepsNameAndLiveTitle() async throws {
    let (fixture, workspace) = await installed()
    #expect(
      await fixture.store.apply(
        .fixture(cursor: 5, panes: [try record(in: workspace, liveTitle: "vim")]), machineId: "m"))
    let (_, pane) = try shownTerminal(fixture, workspace)

    let published = WorkspaceSyncModel.serverPane(from: pane, workspaceId: workspace.id, createdAt: Date())
    #expect(published.title == "Terminal 1")
    #expect(published.liveTitle == nil)

    fixture.workspaceSync.publishPane(pane, workspaceId: workspace.id)
    #expect(fixture.store.pendingIntents.count == 1)
    #expect(try shownTerminal(fixture, workspace).1.displayName == "vim")
  }

  @Test("Confirming the shown live title is not a rename; a real rename wins over it")
  func renamePrecedence() async throws {
    let (fixture, workspace) = await installed()
    #expect(
      await fixture.store.apply(
        .fixture(cursor: 5, panes: [try record(in: workspace, liveTitle: "npm test")]), machineId: "m"))
    let tabId = try shownTerminal(fixture, workspace).0.id

    fixture.workspaceSync.renameTab(workspaceId: workspace.id, tabId: tabId, to: "npm test")
    #expect(try shownTerminal(fixture, workspace).0.customTitle == nil)

    fixture.workspaceSync.renameTab(workspaceId: workspace.id, tabId: tabId, to: "Tests")
    let (tab, pane) = try shownTerminal(fixture, workspace)
    #expect(tab.displayTitle(for: pane, chatTitle: nil) == "Tests")
  }

  @Test(
    "A chosen pane name outranks the program's title; a default one doesn't",
    arguments: [
      ("Terminal 3", "htop", "htop"),
      ("Terminal", "htop", "htop"),
      ("Dev server", "node", "Dev server"),
      // Nothing running: default names, numbered or not, read "Terminal".
      ("Terminal 3", " \n ", "Terminal"),
    ])
  func paneNamePrecedence(name: String, liveTitle: String, shown: String) {
    let pane = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: name, terminalKey: "t",
      liveTitle: PaneDescriptorState.normalizedLiveTitle(liveTitle))
    #expect(pane.displayName == shown)
  }
}

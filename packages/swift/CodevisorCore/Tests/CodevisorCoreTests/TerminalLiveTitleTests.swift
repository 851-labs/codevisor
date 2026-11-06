import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct TerminalLiveTitleTests {
  let project = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "m")
  let terminal = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal 1", terminalKey: "t1")

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

  func record(in workspace: Workspace, liveTitle: String?) throws -> ServerWorkspacePane {
    let liveTitleField = liveTitle.map { #","liveTitle":\#(String(reflecting: $0))"# } ?? ""
    let json = """
      {"id":"\(terminal.id.uuidString.lowercased())","workspaceId":"\(workspace.id.uuidString.lowercased())",\
      "providerId":"codevisor","paneType":"terminal","title":"Terminal 1","resourceKind":"terminal",\
      "resourceId":"t1","createdAt":"2026-01-01T00:00:00.000Z"\(liveTitleField)}
      """
    return try JSONDecoder().decode(ServerWorkspacePane.self, from: Data(json.utf8))
  }

  func shownTerminal(_ fixture: NavigationFixture, _ workspace: Workspace) throws -> PaneDescriptorState {
    let shown = try #require(fixture.workspaces.workspace(id: workspace.id))
    let tab = try #require(shown.centerTabs.first { $0.root.allGroups.first?.state.selectedPane?.id == terminal.id })
    return try #require(tab.root.allGroups.first?.state.selectedPane)
  }

  @Test("A title-only event retitles the terminal, and its absence restores the pane's name")
  func liveTitleEvents() async throws {
    let (fixture, workspace) = await installed()

    #expect(
      await fixture.store.apply(
        .fixture(cursor: 5, panes: [try record(in: workspace, liveTitle: "  ✳ Claude Code\n")]), machineId: "m"))
    var pane = try shownTerminal(fixture, workspace)
    #expect(pane.name == "Terminal 1")
    #expect(pane.displayName == "✳ Claude Code")

    #expect(
      await fixture.store.apply(
        .fixture(cursor: 6, panes: [try record(in: workspace, liveTitle: nil)]), machineId: "m"))
    pane = try shownTerminal(fixture, workspace)
    #expect(pane.liveTitle == nil)
    #expect(pane.displayName == "Terminal")
  }

  @Test("Publishing the pane sends its name, and a waiting publish keeps showing the live title")
  func publishKeepsNameAndLiveTitle() async throws {
    let (fixture, workspace) = await installed()
    #expect(
      await fixture.store.apply(
        .fixture(cursor: 5, panes: [try record(in: workspace, liveTitle: "vim")]), machineId: "m"))
    let pane = try shownTerminal(fixture, workspace)

    let published = ServerPaneMapping.record(from: pane, workspaceId: workspace.id, createdAt: Date())
    #expect(published.title == "Terminal 1")
    #expect(published.liveTitle == nil)

    fixture.workspaceSync.publishPane(pane, workspaceId: workspace.id)
    #expect(fixture.store.pendingIntents.count == 1)
    #expect(try shownTerminal(fixture, workspace).displayName == "vim")
  }

  @Test(
    "A chosen pane name outranks the program's title; a default one doesn't",
    arguments: [
      ("Terminal 3", "htop", "htop"),
      ("Terminal", "htop", "htop"),
      ("Dev server", "node", "Dev server"),
      ("Terminal 3", " \n ", "Terminal"),
    ])
  func paneNamePrecedence(name: String, liveTitle: String, shown: String) {
    let pane = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: name, terminalKey: "t",
      liveTitle: PaneDescriptorState.normalizedLiveTitle(liveTitle))
    #expect(pane.displayName == shown)
  }
}

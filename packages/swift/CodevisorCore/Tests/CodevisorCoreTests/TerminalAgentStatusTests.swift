import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

/// A terminal's agent activity is server-owned: it arrives on the pane
/// record and shows as the chat's working indicator.
@MainActor
struct TerminalAgentStatusTests {
  let terminal = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal 1", terminalKey: "t1")

  /// The shared workspace's chat tab plus a selected terminal tab.
  func fixture() async -> WorkspaceSyncFixture {
    let terminal = terminal
    return await WorkspaceSyncFixture { workspace, _ in
      workspace.upsertCenterPane(terminal, selecting: true)
    }
  }

  func shownTerminal(_ fixture: WorkspaceSyncFixture) throws -> PaneDescriptorState {
    try #require(fixture.current?.allPanes.first { $0.id == terminal.id })
  }

  /// The server records a change in the terminal's agent activity, and the
  /// device receives its `navigation.changed` event.
  func serverSets(_ fixture: WorkspaceSyncFixture, activity: String?) async throws {
    var record = try #require(
      fixture.server.panes(in: fixture.workspace.id).first { UUID(uuidString: $0.id) == terminal.id })
    record.terminalActivity = activity
    fixture.server.commit(panes: [record])
    await fixture.deliver()
  }

  @Test(
    "Pane records carry terminal activity when present and decode without it from older servers",
    arguments: [
      (#","terminalActivity":"working""#, TerminalActivity.working),
      (#","terminalActivity":"idle""#, .idle),
      ("", nil),
      // A value this client doesn't know yet must not drop the pane.
      (#","terminalActivity":"thinking""#, nil),
    ] as [(String, TerminalActivity?)])
  func decoding(fields: String, activity: TerminalActivity?) throws {
    let json = """
      {"id":"\(terminal.id.uuidString.lowercased())","workspaceId":"\(UUID().uuidString.lowercased())",\
      "providerId":"codevisor","paneType":"terminal","title":"Terminal 1","resourceKind":"terminal",\
      "resourceId":"t1","createdAt":"2026-01-01T00:00:00.000Z"\(fields)}
      """
    let record = try JSONDecoder().decode(ServerWorkspacePane.self, from: Data(json.utf8))
    let pane = try #require(WorkspaceSyncModel.descriptor(from: record))
    #expect(pane.terminalActivity == activity)
  }

  @Test("A layout saved before terminal status still decodes, with no status")
  func persistedLayoutWithoutStatus() throws {
    let json = #"{"id":"\#(terminal.id.uuidString)","kind":"terminal","name":"Terminal 1","terminalKey":"t1"}"#
    let pane = try JSONDecoder().decode(PaneDescriptorState.self, from: Data(json.utf8))
    #expect(pane.terminalAgentStatus == nil)
  }

  @Test(
    "Only a working agent shows the working indicator; otherwise a terminal shows its ordinary icon",
    arguments: [
      (PaneKind.terminal, TerminalActivity.working, AgentPaneStatus.working),
      (.terminal, .idle, nil),
      (.terminal, nil, nil),
      (.chat, .working, nil),
    ] as [(PaneKind, TerminalActivity?, AgentPaneStatus?)])
  func status(kind: PaneKind, activity: TerminalActivity?, expected: AgentPaneStatus?) {
    let pane = PaneDescriptorState(
      id: terminal.id, kind: kind, name: "Pane", terminalKey: "t1", terminalActivity: activity)
    #expect(pane.terminalAgentStatus == expected)
  }

  @Test("An event that changes only the terminal's activity updates the workspace on screen")
  func activityOnlyEvents() async throws {
    let fixture = await fixture()
    let entry = fixture.store.workspaceEntries.entry(fixture.workspace.id)

    var generation = entry.generation
    try await serverSets(fixture, activity: "working")
    #expect(entry.generation != generation)
    #expect(try shownTerminal(fixture).terminalAgentStatus == .working)

    generation = entry.generation
    try await serverSets(fixture, activity: "idle")
    #expect(entry.generation != generation)
    #expect(try shownTerminal(fixture).terminalAgentStatus == nil)
  }

  @Test("Publishing a terminal never sends its activity, and a waiting publish keeps showing it")
  func publishOmitsActivity() async throws {
    let fixture = await fixture()
    try await serverSets(fixture, activity: "working")
    let pane = try shownTerminal(fixture)

    let published = WorkspaceSyncModel.serverPane(from: pane, workspaceId: fixture.workspace.id, createdAt: Date())
    #expect(published.terminalActivity == nil)

    fixture.sync.publishPane(pane, workspaceId: fixture.workspace.id)
    #expect(fixture.store.pendingIntents.count == 1)
    #expect(try shownTerminal(fixture).terminalActivity == .working)
  }
}

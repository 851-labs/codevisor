import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Shell sync events", .timeLimit(.minutes(1)))
struct ShellSyncEventTests {
  @Test("Harness, MCP and sync events reach their callbacks with the decoded payload")
  func eventsReachCallbacks() async {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    let controller = makeController(fake)
    defer { controller.stopEventSync() }
    var calls: [String] = []
    let synced = TestSignal()
    controller.onHarnessLifecycleChanged = { calls.append("lifecycle \($0)") }
    controller.onMcpStateChanged = { calls.append("mcp \($0)") }
    controller.onHarnessNotice = { calls.append("notice \($0.id) \($0.message)") }
    controller.onSyncChanged = {
      calls.append("sync \($0) \($1.namespace) \($1.entries.count)")
      synced.signal()
    }

    controller.startEventSync(serverId: "local", client: controller.client(for: "local"), since: 0)
    fake.emit(kind: "harness.lifecycle.updated", subjectId: "codex")
    fake.emit(kind: "mcp.updated", subjectId: "server")
    fake.emit(
      kind: "harness.notice", subjectId: "codex",
      payload: .object(["id": .string("n1"), "message": .string("Signed out")]))
    fake.emit(
      kind: "sync.changed", subjectId: "skills",
      payload: .object(["namespace": .string("skills"), "entries": .array([])]))
    await synced.wait()

    #expect(calls == ["lifecycle local", "mcp local", "notice n1 Signed out", "sync local skills 0"])
  }

  @Test("Events whose payload is missing a required field change nothing")
  func incompletePayloadsAreDropped() async {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    let controller = makeController(fake)
    defer { controller.stopEventSync() }
    var calls: [String] = []
    let reachedEnd = TestSignal()
    controller.onHarnessNotice = { _ in calls.append("notice") }
    controller.onSyncChanged = { _, _ in calls.append("sync") }
    controller.onMcpStateChanged = { _ in reachedEnd.signal() }

    controller.startEventSync(serverId: "local", client: controller.client(for: "local"), since: 0)
    fake.emit(kind: "harness.notice", subjectId: "codex", payload: .object(["id": .string("n1")]))
    fake.emit(
      kind: "update.changed", subjectId: "server",
      payload: .object(["currentVersion": .string("0.1.0"), "latestVersion": .string("9.9.9")]))
    fake.emit(kind: "restart.drain.updated", subjectId: "server", payload: .object(["state": .string("drained")]))
    fake.emit(kind: "update.run.updated", subjectId: "server", payload: .object(["state": .string("pausing")]))
    fake.emit(kind: "sync.changed", subjectId: "skills", payload: .object(["namespace": .string("skills")]))
    fake.emit(kind: "mcp.updated", subjectId: "server")
    await reachedEnd.wait()

    #expect(calls.isEmpty)
    #expect(controller.connectionsById["local"]?.updateInfo == nil)
    #expect(controller.updatePauseSubject(machineId: "local", sessionId: nil, harnessId: nil) == nil)
    #expect(controller.connectionsById["local"]?.updateRun == .idle)
  }

  @Test("Archives and sandbox setting changes ask the picker to check sandboxes again; other syncs don't")
  func sandboxRechecks() async {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    let controller = makeController(fake)
    defer { controller.stopEventSync() }
    let reachedEnd = TestSignal()
    controller.onMcpStateChanged = { _ in reachedEnd.signal() }
    let before = controller.sandboxProfilesLoadKey(composerId: "local")

    controller.startEventSync(serverId: "local", client: controller.client(for: "local"), since: 0)
    fake.emit(
      kind: "sync.changed", subjectId: "skills",
      payload: .object(["namespace": .string("skills"), "entries": .array([])]))
    fake.emit(kind: "mcp.updated", subjectId: "server")
    await reachedEnd.wait()
    #expect(controller.sandboxProfilesLoadKey(composerId: "local") == before)

    let archived = ServerWorkspace(
      id: "workspace-a", serverId: "local", projectId: "project-a", name: "Old VM chat", hasCustomName: false,
      isArchived: true, createdAt: "2026-10-29T00:00:00.000Z")
    fake.emit(kind: "workspace.updated", subjectId: archived.id, payload: navigationFixtureJSON(archived))
    fake.emit(kind: "workspace.deleted", subjectId: "workspace-b")
    fake.emit(
      kind: "sync.changed", subjectId: "sandbox-profiles",
      payload: .object(["namespace": .string("sandbox-profiles"), "entries": .array([])]))
    fake.emit(kind: "mcp.updated", subjectId: "server")
    await reachedEnd.wait(for: 2)

    #expect(controller.sandboxAvailabilityRevision == 3)
  }

  private func makeController(_ fake: SyncFakeServerClient) -> MachineController {
    let navigation = NavigationFixture()
    return MachineController(
      store: InMemoryStore(),
      projectList: navigation.projectList,
      workspaceSync: navigation.workspaceSync,
      clientFactory: { _ in fake }
    )
  }
}

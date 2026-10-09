import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct NavigationHierarchyTests {
  private static func stamp(_ milliseconds: Int64, _ device: String = "mac") -> String {
    NavigationClock.stamp(milliseconds: milliseconds, counter: 0, device: device)
  }

  private static func folder(_ name: String, revision: String, deleted: Bool = false) -> ServerNavigationFolder {
    ServerNavigationFolder(
      id: "0000000f-0000-0000-0000-000000000001", name: name, position: "8", deleted: deleted,
      revision: revision)
  }

  private static func snapshot(
    cursor: Int = 1, workspaces: [ServerWorkspace] = [], records: ServerNavigationRecords = .init()
  ) -> ServerNavigationSnapshot {
    ServerNavigationSnapshot(
      eventCursor: cursor, projects: [], sessions: [], workspaces: workspaces, panes: [], records: records)
  }

  private static func workspace(_ id: UUID, parent: UUID? = nil) -> ServerWorkspace {
    var record = ServerWorkspace(
      id: id.uuidString, serverId: "local", projectId: UUID().uuidString, name: "Work", hasCustomName: false,
      isArchived: false, createdAt: "2026-10-08T00:00:00.000Z")
    record.parentWorkspaceId = parent?.uuidString.lowercased()
    record.parentTabPosition = parent == nil ? nil : "000000000001888"
    return record
  }

  @Test("Records merge by newest revision on every side, so replays and older copies change nothing")
  func recordsMerge() {
    let base = ServerNavigationRecords(folders: [Self.folder("Payments", revision: Self.stamp(2))])
    #expect(base.merging(.init(folders: [Self.folder("Old", revision: Self.stamp(1))])) == base)
    let tombstoned = base.merging(.init(folders: [Self.folder("Payments", revision: Self.stamp(3), deleted: true)]))
    #expect(tombstoned.folders.map(\.deleted) == [true])
    // Same millisecond on two devices: the stamps still order one way.
    let tie = base.merging(.init(settings: [.init(key: "k", value: "ios", revision: Self.stamp(5, "ios"))]))
      .merging(.init(settings: [.init(key: "k", value: "mac", revision: Self.stamp(5, "mac"))]))
    #expect(tie.settings.map(\.value) == ["mac"])
  }

  @Test("The clock issues increasing stamps and stays above stamps written elsewhere")
  func clock() {
    var wall = Date(timeIntervalSince1970: 100)
    let store = InMemoryStore()
    let clock = NavigationClock(store: store, now: { wall })
    let first = clock.next()
    let second = clock.next()
    #expect(first < second)
    // A device whose wall clock runs ahead wrote last; this one still wins next.
    let ahead = Self.stamp(500_000, "ipad")
    clock.witness(ahead)
    #expect(clock.next() > ahead)
    wall = Date(timeIntervalSince1970: 1_000)
    #expect(clock.next() > ahead)
    // The device id survives relaunches.
    #expect(NavigationClock(store: store, now: { wall }).deviceId == clock.deviceId)
  }

  @Test("A folder edit goes to every machine, and a machine missing a newer copy is filled in once")
  func replication() async {
    let fixture = NavigationFixture()
    let store = fixture.store
    let held = Self.folder("Payments", revision: Self.stamp(2))
    await store.replace(Self.snapshot(records: .init(folders: [held])), machineId: "a", requestedAt: Date())
    await store.replace(Self.snapshot(), machineId: "b", requestedAt: Date())
    let pending = { (machine: String) in store.pendingIntents.filter { $0.machineId == machine }.map(\.intent) }
    #expect(pending("a").isEmpty)
    #expect(pending("b") == [.putNavigationFolder(held)])
    store.replicateNavigationRecords()
    #expect(pending("b").count == 1)
    #expect(store.folders.map(\.name) == ["Payments"])

    let ops = UUID()
    store.saveFolder(id: ops, name: "Ops", position: "9")
    #expect(store.folders.map(\.name) == ["Payments", "Ops"])
    #expect(pending("a").count == 1)
    #expect(pending("b").count == 2)
    store.deleteFolder(id: ops)
    #expect(store.folders.map(\.name) == ["Payments"])
    #expect(store.sidebarGrouping == .none)
    #expect(store.showsSubagents)
    store.setSetting(NavigationStore.sidebarGroupingKey, value: "project")
    store.setSetting(NavigationStore.sidebarSubagentsKey, value: "hidden")
    #expect(store.sidebarGrouping == .project)
    #expect(!store.showsSubagents)
    #expect(store.agentSidebar.isEmpty)
  }

  @Test("A newer record arriving from one machine is copied to the others")
  func replicatesLiveChanges() async {
    let fixture = NavigationFixture()
    let store = fixture.store
    await store.replace(Self.snapshot(), machineId: "a", requestedAt: Date())
    await store.replace(Self.snapshot(), machineId: "b", requestedAt: Date())
    let renamed = Self.folder("Billing", revision: Self.stamp(9, "ios"))
    _ = await store.apply(ServerNavigationDelta(eventCursor: 2, records: .init(folders: [renamed])), machineId: "a")
    #expect(store.pendingIntents.map(\.machineId) == ["b"])
    #expect(store.folders.map(\.name) == ["Billing"])
  }

  @Test("Ownership, group and folder changes show at once, before the server has them")
  func hierarchyOverlay() async {
    let fixture = NavigationFixture()
    let store = fixture.store
    let parent = UUID()
    let child = UUID()
    await store.replace(
      Self.snapshot(workspaces: [Self.workspace(parent), Self.workspace(child, parent: parent)]),
      machineId: "local", requestedAt: Date())
    let projected = { store.projection.workspacesById[child] }
    #expect(projected()?.parentWorkspaceId == parent)
    #expect(projected()?.parentTabPosition == "000000000001888")

    store.enqueue(.updateWorkspaceHierarchy(workspaceId: child, change: .groupCollapsed(true)), machineId: "local")
    store.enqueue(
      .updateWorkspaceHierarchy(workspaceId: child, change: .groupPosition("0000000000018")), machineId: "local")
    #expect(projected()?.groupCollapsed == true)
    #expect(projected()?.parentTabPosition == "0000000000018")

    store.enqueue(.updateWorkspaceHierarchy(workspaceId: child, change: .owner(nil)), machineId: "local")
    #expect(projected()?.parentWorkspaceId == nil)
    #expect(projected()?.parentTabPosition == nil)
    // Without an owner there is no group to move.
    store.enqueue(.updateWorkspaceHierarchy(workspaceId: child, change: .groupPosition("1")), machineId: "local")
    #expect(projected()?.parentTabPosition == nil)

    let folder = UUID()
    store.enqueue(.updateWorkspaceHierarchy(workspaceId: child, change: .folder(folder)), machineId: "local")
    #expect(projected()?.folderId == folder)
    store.enqueue(.updateWorkspaceHierarchy(workspaceId: parent, change: .owner(child)), machineId: "local")
    #expect(store.projection.workspacesById[parent]?.parentWorkspaceId == child)
    #expect(store.pendingIntents.map(\.intent.coalescingKey).count == 5)
  }

  @Test("Server records decode the parent chat, the hierarchy fields and omitted records")
  func decoding() throws {
    let json = #"""
      {"eventCursor":3,"projects":[],"workspaces":[],"panes":[],"deleted":[],
       "sessions":[{"id":"6f1c2a3e-0000-4000-8000-000000000001","projectId":"6f1c2a3e-0000-4000-8000-000000000002",
         "serverId":"local","harnessId":"codex","title":"Child","origin":"codevisor",
         "createdAt":"2026-10-08T00:00:00.000Z","parentSessionId":"6f1c2a3e-0000-4000-8000-000000000003"}],
       "folders":[{"id":"f","name":"Ops","position":"8","collapsed":true,"deleted":false,"revision":"0000000000001-000000-mac"}]}
      """#
    let delta = try JSONDecoder().decode(ServerNavigationDelta.self, from: Data(json.utf8))
    #expect(delta.records.folders.map(\.name) == ["Ops"])
    #expect(delta.records.settings.isEmpty)
    let session = try #require(delta.sessions.first).chatSession(serverId: "local")
    #expect(session.parentSessionId == UUID(uuidString: "6f1c2a3e-0000-4000-8000-000000000003"))
    let roundTrip = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(session))
    #expect(roundTrip.parentSessionId == session.parentSessionId)

    let bare = #"{"eventCursor":1,"projects":[],"sessions":[],"workspaces":[],"panes":[]}"#
    let snapshot = try JSONDecoder().decode(ServerNavigationSnapshot.self, from: Data(bare.utf8))
    #expect(snapshot.records.isEmpty)
    let encoded = try JSONDecoder().decode(ServerNavigationSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(encoded == snapshot)
  }
}

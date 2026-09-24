import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct NavigationOutboxTests {
  let workspaceId = UUID()

  @Test("An unsent change replaces the older one with the same key, keeping the order of different changes")
  func coalescesInPlace() {
    let outbox = NavigationOutbox(store: InMemoryStore())
    outbox.enqueue(.renameWorkspace(workspaceId: workspaceId, name: "A", hasCustomName: true), machineId: "m")
    outbox.enqueue(.setWorkspaceArchived(workspaceId: workspaceId, isArchived: true), machineId: "m")
    outbox.enqueue(.renameWorkspace(workspaceId: workspaceId, name: "B", hasCustomName: true), machineId: "m")
    #expect(
      outbox.entries.map(\.intent) == [
        .renameWorkspace(workspaceId: workspaceId, name: "B", hasCustomName: true),
        .setWorkspaceArchived(workspaceId: workspaceId, isArchived: true),
      ])
    // The same key on another machine is a different record.
    outbox.enqueue(.renameWorkspace(workspaceId: workspaceId, name: "C", hasCustomName: true), machineId: "other")
    #expect(outbox.entries.count == 3)
  }

  @Test("A change never merges into a request that is already being sent")
  func doesNotCoalesceInFlight() {
    let outbox = NavigationOutbox(store: InMemoryStore())
    outbox.enqueue(.renameWorkspace(workspaceId: workspaceId, name: "A", hasCustomName: true), machineId: "m")
    outbox.inFlight.insert(outbox.entries[0].id)
    outbox.enqueue(.renameWorkspace(workspaceId: workspaceId, name: "B", hasCustomName: true), machineId: "m")
    #expect(outbox.entries.count == 2)
  }

  @Test("An accepted change leaves once the cache reaches its cursor, or a later snapshot replaces the cache")
  func retirement() {
    let outbox = NavigationOutbox(store: InMemoryStore())
    let accepted = Date(timeIntervalSince1970: 100)
    outbox.enqueue(.renameWorkspace(workspaceId: workspaceId, name: "A", hasCustomName: true), machineId: "m")
    outbox.enqueue(.setWorkspaceArchived(workspaceId: workspaceId, isArchived: true), machineId: "m")
    outbox.markAccepted(outbox.entries[0].id, cursor: 10, at: accepted)
    outbox.markAccepted(outbox.entries[1].id, cursor: 20, at: accepted)

    #expect(!outbox.retire(machineId: "m", cursor: 9, snapshotRequestedAt: nil))
    #expect(outbox.retire(machineId: "m", cursor: 10, snapshotRequestedAt: nil))
    #expect(outbox.entries.count == 1)
    // A snapshot requested before the server accepted the change may not
    // contain it; one requested after must (even if the log was reset).
    #expect(!outbox.retire(machineId: "m", cursor: 1, snapshotRequestedAt: accepted.addingTimeInterval(-1)))
    #expect(outbox.retire(machineId: "m", cursor: 1, snapshotRequestedAt: accepted.addingTimeInterval(1)))
    #expect(outbox.entries.isEmpty)
  }

  @Test("A pending change is never retired by the cache, only accepted ones")
  func pendingStays() {
    let outbox = NavigationOutbox(store: InMemoryStore())
    outbox.enqueue(.renameWorkspace(workspaceId: workspaceId, name: "A", hasCustomName: true), machineId: "m")
    outbox.retire(machineId: "m", cursor: .max, snapshotRequestedAt: .distantFuture)
    #expect(outbox.entries.count == 1)
  }

  @Test("A request that keeps failing is given up after the attempt limit")
  func attemptLimit() {
    let outbox = NavigationOutbox(store: InMemoryStore())
    outbox.enqueue(.renameWorkspace(workspaceId: workspaceId, name: "A", hasCustomName: true), machineId: "m")
    let id = outbox.entries[0].id
    for _ in 1..<NavigationOutbox.maximumAttempts { #expect(outbox.noteFailure(id)) }
    #expect(!outbox.noteFailure(id))
    #expect(outbox.entries.isEmpty)
  }

  @Test("Waiting changes survive the app being killed")
  func persistence() {
    let store = InMemoryStore()
    let outbox = NavigationOutbox(store: store)
    outbox.enqueue(.setWorkspaceArchived(workspaceId: workspaceId, isArchived: true), machineId: "m")
    PersistenceEncoding.drain()
    let reopened = NavigationOutbox(store: store)
    #expect(reopened.entries.map(\.intent) == [.setWorkspaceArchived(workspaceId: workspaceId, isArchived: true)])
  }

  @Test("An expected chat leaves once the server lists it")
  func expectedSessionRetires() {
    let outbox = NavigationOutbox(store: InMemoryStore())
    let chat = ChatSession(projectId: UUID(), title: "New Chat")
    outbox.enqueue(.expectSession(chat), machineId: "m")
    #expect(!outbox.retireExpectedSessions(machineId: "m", listed: [UUID()]))
    #expect(outbox.retireExpectedSessions(machineId: "m", listed: [chat.id]))
    #expect(outbox.entries.isEmpty)
  }

  @Test(
    "Failures are sorted into done, refused, and try again",
    arguments: [
      (404, true, NavigationOutboxExecutor.Outcome.alreadyDone),
      (404, false, .rejected),
      (409, false, .rejected),
      (408, false, .retryLater(countsAsAttempt: false)),
      (429, false, .retryLater(countsAsAttempt: false)),
      (500, false, .retryLater(countsAsAttempt: true)),
    ])
  func classification(status: Int, isRemoval: Bool, expected: NavigationOutboxExecutor.Outcome) {
    let error = CodevisorServerClientError.httpStatus(status, "")
    #expect(NavigationOutboxExecutor.classify(error, isRemoval: isRemoval) == expected)
  }

  @Test("An unreachable machine never uses up an attempt")
  func transportFailure() {
    #expect(
      NavigationOutboxExecutor.classify(URLError(.notConnectedToInternet), isRemoval: false)
        == .retryLater(countsAsAttempt: false))
  }
}

@MainActor
struct NavigationOutboxExecutorTests {
  @Test("Requests reach the machine in the order they were made, and only once it is ready")
  func fifoAndReadiness() async {
    let workspace = Workspace(
      name: "W", rootDirectory: "/w", serverId: "m", projectId: UUID(), centerTree: .leaf(PaneGroupState()),
      isServerSynced: true)
    let fake = SyncFakeServerClient(projects: [], sessions: [], panes: [])
    let fixture = NavigationFixture()
    await fixture.install(machineId: "m", workspaces: [workspace])
    var ready = false
    fixture.store.executor.isMachineReady = { _ in ready }
    fixture.store.executor.clientProvider = { _ in fake }
    let pane = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal", terminalKey: "t1")
    fixture.workspaceSync.publishPane(pane, workspaceId: workspace.id)
    fixture.workspaceSync.deletePane(id: pane.id, workspaceId: workspace.id)
    await fixture.store.executor.idle(machineId: "m")
    #expect(fake.paneMutationLog.isEmpty)

    ready = true
    fixture.store.executor.resume(machineId: "m")
    await fixture.store.executor.idle(machineId: "m")
    // Closing a pane whose create was never sent replaces that create: the
    // server never sees the close ahead of it, and never sees the pane.
    #expect(fake.paneMutationLog == ["close"])
  }

  @Test("A draft workspace's requests wait until the server has the workspace")
  func draftHold() async {
    let fake = SyncFakeServerClient(projects: [], sessions: [], panes: [])
    let fixture = NavigationFixture()
    fixture.store.executor.isMachineReady = { _ in true }
    fixture.store.executor.clientProvider = { _ in fake }
    let chatId = UUID()
    let draft = fixture.workspaces.ensureWorkspace(
      for: WorkspaceSessionSeed(
        sessionId: chatId, initialName: "Draft", serverId: "m", projectId: UUID(), rootDirectory: "/d"),
      legacyGroups: nil)
    #expect(draft.isDraft)
    let pane = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal", terminalKey: "t1")
    fixture.store.enqueue(.upsertPane(pane, workspaceId: draft.id), machineId: "m")
    await fixture.store.executor.idle(machineId: "m")
    #expect(fake.paneMutationLog.isEmpty)

    // Opening the draft's first chat creates it on the server.
    var created = draft
    created.isServerSynced = true
    await fixture.install(machineId: "m", workspaces: [created], cursor: 2)
    #expect(fixture.workspaces.workspace(id: draft.id)?.isDraft == false)
    fixture.store.executor.resume(machineId: "m")
    await fixture.store.executor.idle(machineId: "m")
    #expect(fake.paneMutationLog == ["upsert"])
  }
}

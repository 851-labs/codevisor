import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineControllerAttentionSyncTests {
  @Test(
    "Both clients apply every background chat state while another chat stays focused", arguments: ["local", "remote"])
  func backgroundStatePropagation(serverId: String) async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/shared-attention"))
    let foreground = ChatSession(projectId: project.id, serverId: serverId, title: "Open chat")
    let background = ChatSession(
      projectId: project.id, serverId: serverId, title: "Background chat",
      createdAt: Date(timeIntervalSince1970: 0)
    )
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    let clients = (0..<2).map { _ in
      Client(fake: fake, foreground: foreground, background: background)
    }
    defer { clients.forEach { $0.machine.stopEventSync() } }

    struct State {
      var sidebar: SessionSidebarState
      var latest = 0
      var seen = 0
      var unread = 0
      var error = false
      var action = false
      var plan = false
    }
    let states: [State] = [
      State(sidebar: .inProgress),
      State(sidebar: .waitingForUser, action: true, plan: true),
      State(sidebar: .inProgress),
      State(sidebar: .unread, latest: 1, unread: 1),
      // A read from another client clears the shared unread state.
      State(sidebar: .idle, latest: 1, seen: 1),
      // Manual unread changes no attention sequence and must stay silent.
      State(sidebar: .unread, latest: 1, seen: 1, unread: 1),
      State(sidebar: .idle, latest: 1, seen: 1),
      State(sidebar: .errored, latest: 2, seen: 1, unread: 1, error: true),
      State(sidebar: .idle, latest: 2, seen: 2),
    ]
    for (index, state) in states.enumerated() {
      let payload: JSONValue = .object([
        "id": .string(background.id.uuidString),
        "projectId": .string(project.id.uuidString),
        "serverId": .string("local"),
        "title": .string(background.title),
        "harnessId": .string("codex"),
        "origin": .string("codevisor"),
        "isArchived": .bool(false),
        "createdAt": .string("2026-09-15T00:00:00.000Z"),
        "sidebarState": .string(state.sidebar.rawValue),
        "sidebarStateChangedAt": .string("2026-09-15T00:00:0\(index).000Z"),
        "latestAttentionSequence": .number(Double(state.latest)),
        "lastSeenAttentionSequence": .number(Double(state.seen)),
        "unreadCount": .number(Double(state.unread)),
        "hasUnreadError": .bool(state.error),
        "actionRequired": .bool(state.action),
        "pendingPlanApproval": .bool(state.plan),
      ])
      fake.emit(kind: "session.attention.updated", subjectId: background.id.uuidString, payload: payload)
      for client in clients {
        await client.applied.wait(for: index + 1)
        let session = try #require(client.model.sessions.first { $0.id == background.id })
        #expect(session.serverId == serverId)
        #expect(session.sidebarState == state.sidebar)
        #expect(session.unreadCount == state.unread)
        #expect(session.hasUnreadError == state.error)
        #expect(session.actionRequired == state.action)
        #expect(session.pendingPlanApproval == state.plan)
        #expect(session.lastSeenAttentionSequence == state.seen)
        #expect(client.coordinator.focusedSession?.sessionId == foreground.id)
      }
    }
    #expect(fake.listSessionCallCount == 0)
    for client in clients {
      #expect(client.delivery.delivered.map(\.kind) == [.actionRequired, .finished, .actionRequired])
      #expect(client.delivery.cleared.contains(background.id))
      let stream = client.machine.connection(for: serverId).eventSyncTask
      client.machine.stopEventSync()
      await stream?.value
    }
  }
}

@MainActor
private final class Client {
  let model: ProjectListModel
  let machine: MachineController
  let coordinator: SessionAttentionCoordinator
  let delivery = AttentionDelivery()
  let applied = TestSignal()

  init(fake: SyncFakeServerClient, foreground: ChatSession, background: ChatSession) {
    model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
    model.sessions = [foreground, background]
    coordinator = SessionAttentionCoordinator(projectList: model)
    coordinator.notificationDelivery = delivery
    coordinator.updateFocus(
      owner: ObjectIdentifier(delivery),
      session: SessionAttentionFocus(serverId: foreground.serverId, sessionId: foreground.id)
    )
    machine = MachineController(store: InMemoryStore(), projectList: model, clientFactory: { _ in fake })
    let applied = applied
    machine.onSessionStateChanged = { _, _ in applied.signal() }
    machine.connection(for: background.serverId).navigationSnapshot = ServerNavigationSnapshot(
      eventCursor: 0,
      projects: [
        ServerProject(
          id: background.projectId.uuidString, name: "Shared", origin: .codevisor,
          createdAt: "2026-06-30T00:00:00.000Z", locations: [])
      ], sessions: [foreground, background].map { serverSession(from: $0) }, workspaces: [], panes: [])
    machine.startEventSync(serverId: background.serverId, client: fake, since: 0)
  }
}

@MainActor
private final class AttentionDelivery: ChatNotificationDelivering {
  var delivered: [ChatAttentionEvent] = []
  var cleared: [UUID] = []
  func deliver(_ event: ChatAttentionEvent) { delivered.append(event) }
  func clearNotifications(for sessionId: UUID) { cleared.append(sessionId) }
  func prepareAuthorizationIfNeeded() async {}
}

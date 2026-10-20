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
    var clients: [Client] = []
    for _ in 0..<2 {
      clients.append(await Client(fake: fake, project: project, foreground: foreground, background: background))
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
      State(sidebar: .idle, latest: 1, seen: 1),
      State(sidebar: .unread, latest: 1, seen: 1, unread: 1),
      State(sidebar: .idle, latest: 1, seen: 1),
      State(sidebar: .errored, latest: 2, seen: 1, unread: 1, error: true),
      State(sidebar: .idle, latest: 2, seen: 2),
    ]
    do {
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
    } catch {
      for client in clients {
        await client.shutdown(serverId: serverId)
      }
      throw error
    }
    #expect(fake.listSessionCallCount == 0)
    for client in clients {
      #expect(client.delivery.delivered.map(\.kind) == [.actionRequired, .finished, .actionRequired])
      #expect(client.delivery.cleared.contains(background.id))
      await client.shutdown(serverId: serverId)
    }
  }

  @Test("A bot chat pings only for messages it sends, and reading it on one client clears every client")
  func botConversationAttention() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/bot-attention"))
    let other = ChatSession(projectId: project.id, title: "Open chat")
    let bot = ChatSession(projectId: project.id, title: "Release Helper", createdAt: Date(timeIntervalSince1970: 0))
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    let reader = await Client(fake: fake, project: project, foreground: other, background: bot)
    let watcher = await Client(fake: fake, project: project, foreground: other, background: bot)
    let clients = [reader, watcher]
    defer { clients.forEach { $0.machine.stopEventSync() } }
    let shipped: JSONValue = .object([
      "text": .string("Release is out"), "attachmentNames": .array([.string("notes.txt")]),
    ])
    var emitted = 0
    func emit(_ sidebar: SessionSidebarState, latest: Int, seen: Int, message: JSONValue = .null) async {
      emitted += 1
      fake.emit(
        kind: "session.attention.updated", subjectId: bot.id.uuidString,
        payload: botAttentionPayload(
          bot, project: project, sidebar: sidebar, latest: latest, seen: seen, message: message, at: emitted))
      for client in clients { await client.applied.wait(for: emitted) }
    }

    await emit(.inProgress, latest: 0, seen: 0)
    await emit(.idle, latest: 0, seen: 0)
    #expect(clients.allSatisfy { $0.delivery.delivered.isEmpty })

    await emit(.unread, latest: 1, seen: 0, message: shipped)
    await emit(.unread, latest: 2, seen: 0, message: shipped)
    for client in clients {
      let notification = try #require(client.delivery.delivered.first)
      #expect(client.delivery.delivered.count == 1)
      #expect(client.model.sessions.first { $0.id == bot.id }?.unreadCount == 2)
      let content = ChatNotificationContent(notification)
      #expect(content.title == "Release Helper")
      #expect(content.body == "Release is out\n📎 notes.txt")
    }

    reader.coordinator.updateFocus(
      owner: ObjectIdentifier(reader.delivery), session: SessionAttentionFocus(serverId: "local", sessionId: bot.id))
    #expect(reader.model.sessions.first { $0.id == bot.id }?.unreadCount == 0)
    #expect(reader.delivery.cleared.contains(bot.id))

    await emit(.idle, latest: 2, seen: 2, message: shipped)
    #expect(watcher.model.sessions.first { $0.id == bot.id }?.unreadCount == 0)
    #expect(watcher.delivery.cleared.contains(bot.id))
    for client in clients { await client.shutdown(serverId: "local") }
  }
}

private func botAttentionPayload(
  _ bot: ChatSession, project: Project, sidebar: SessionSidebarState, latest: Int, seen: Int,
  message: JSONValue, at index: Int
) -> JSONValue {
  .object([
    "id": .string(bot.id.uuidString),
    "projectId": .string(project.id.uuidString),
    "serverId": .string("local"),
    "title": .string(bot.title),
    "harnessId": .string("codex"),
    "origin": .string("codevisor"),
    "createdAt": .string("2026-09-15T00:00:00.000Z"),
    "sidebarState": .string(sidebar.rawValue),
    "sidebarStateChangedAt": .string("2026-09-15T00:00:\(String(format: "%02d", index)).000Z"),
    "latestAttentionSequence": .number(Double(latest)),
    "lastSeenAttentionSequence": .number(Double(seen)),
    "unreadCount": .number(Double(latest - seen)),
    "hasUnreadError": .bool(false),
    "actionRequired": .bool(false),
    "latestBotMessage": message,
  ])
}

@MainActor
private final class Client {
  let fixture: NavigationFixture
  let model: ProjectListModel
  let machine: MachineController
  let coordinator: SessionAttentionCoordinator
  let delivery = AttentionDelivery()
  let applied = TestSignal()

  init(fake: SyncFakeServerClient, project: Project, foreground: ChatSession, background: ChatSession) async {
    let fixture = NavigationFixture()
    self.fixture = fixture
    model = fixture.projectList
    await fixture.install(
      machineId: background.serverId, projects: [project], sessions: [foreground, background], cursor: 0)
    coordinator = SessionAttentionCoordinator(projectList: model)
    coordinator.notificationDelivery = delivery
    coordinator.updateFocus(
      owner: ObjectIdentifier(delivery),
      session: SessionAttentionFocus(serverId: foreground.serverId, sessionId: foreground.id)
    )
    machine = MachineController(store: InMemoryStore(), projectList: model, clientFactory: { _ in fake })
    let applied = applied
    machine.onSessionStateChanged = { _, _ in applied.signal() }
    machine.startEventSync(serverId: background.serverId, client: fake, since: 0)
  }

  func shutdown(serverId: String) async {
    let stream = machine.connection(for: serverId).eventSyncTask
    machine.stopEventSync()
    await stream?.value
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

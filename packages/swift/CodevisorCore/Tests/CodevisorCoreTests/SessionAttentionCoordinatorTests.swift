import Foundation
import Testing
@testable import CodevisorCore

@MainActor
private final class FakeNotificationDelivery: ChatNotificationDelivering {
  var delivered: [ChatAttentionEvent] = []
  var cleared: [UUID] = []

  func deliver(_ event: ChatAttentionEvent) {
    delivered.append(event)
  }

  func clearNotifications(for sessionId: UUID) {
    cleared.append(sessionId)
  }

  func prepareAuthorizationIfNeeded() async {}
}

@MainActor
struct SessionAttentionCoordinatorTests {
  private func summary(
    title: String = "Chat",
    latest: Int = 0,
    lastSeen: Int = 0,
    unread: Int = 0,
    error: Bool = false,
    actionRequired: Bool = false
  ) -> SessionAttentionSummary {
    SessionAttentionSummary(
      ChatSession(
        projectId: UUID(),
        title: title,
        sidebarState: .idle,
        latestAttentionSequence: latest,
        lastSeenAttentionSequence: lastSeen,
        unreadCount: unread,
        hasUnreadError: error,
        actionRequired: actionRequired
      ))
  }

  private func makeModel(
    sessions: [ChatSession] = [],
    projects: [Project] = []
  ) async throws -> (ProjectListModel, FakeServerClient, NavigationFixture) {
    let fakeServer = FakeServerClient(
      projects: projects.map(serverProject(from:)),
      sessions: sessions.map(serverSession(from:))
    )
    let fixture = await NavigationFixture.connected(to: fakeServer)
    #expect(fixture.projectList.sessions.count == sessions.count)
    return (fixture.projectList, fakeServer, fixture)
  }

  @Test("An unfocused live unread edge pings exactly once")
  func unreadEdgePingsOnce() async throws {
    let (model, _, _) = try await makeModel()
    let coordinator = SessionAttentionCoordinator(projectList: model)
    let delivery = FakeNotificationDelivery()
    coordinator.notificationDelivery = delivery
    let sessionId = UUID()

    model.onAttentionTransition?(
      SessionAttentionTransition(
        sessionId: sessionId, serverId: "local",
        old: summary(),
        new: summary(latest: 1, unread: 1),
        origin: .liveEvent
      ))
    #expect(delivery.delivered.map(\.kind) == [.finished])

    model.onAttentionTransition?(
      SessionAttentionTransition(
        sessionId: sessionId, serverId: "local",
        old: summary(latest: 1, unread: 1),
        new: summary(latest: 2, unread: 2),
        origin: .liveEvent
      ))
    #expect(delivery.delivered.count == 1)
  }

  @Test("A background machine's live edge delivers, carrying its serverId")
  func backgroundMachineDelivers() async throws {
    let (model, _, _) = try await makeModel()
    let coordinator = SessionAttentionCoordinator(projectList: model)
    let delivery = FakeNotificationDelivery()
    coordinator.notificationDelivery = delivery
    coordinator.updateFocus(
      owner: ObjectIdentifier(delivery),
      session: SessionAttentionFocus(serverId: "local", sessionId: UUID())
    )

    model.onAttentionTransition?(
      SessionAttentionTransition(
        sessionId: UUID(), serverId: "remote-linux",
        old: summary(),
        new: summary(title: "Linux build", latest: 1, unread: 1),
        origin: .liveEvent
      ))

    #expect(delivery.delivered.map(\.serverId) == ["remote-linux"])
    #expect(delivery.delivered.map(\.sessionTitle) == ["Linux build"])
  }

  @Test("Action-required and error edges ping as actionRequired")
  func actionRequiredEdges() async throws {
    let (model, _, _) = try await makeModel()
    let coordinator = SessionAttentionCoordinator(projectList: model)
    let delivery = FakeNotificationDelivery()
    coordinator.notificationDelivery = delivery

    model.onAttentionTransition?(
      SessionAttentionTransition(
        sessionId: UUID(), serverId: "local",
        old: summary(),
        new: summary(actionRequired: true),
        origin: .liveEvent
      ))
    model.onAttentionTransition?(
      SessionAttentionTransition(
        sessionId: UUID(), serverId: "local",
        old: summary(),
        new: summary(latest: 1, unread: 1, error: true),
        origin: .liveEvent
      ))
    #expect(delivery.delivered.map(\.kind) == [.actionRequired, .actionRequired])
  }

  @Test("The announcement filter sees every window's open chat and can mute an edge")
  func announcementFilterGatesDelivery() async throws {
    let (model, _, _) = try await makeModel()
    let coordinator = SessionAttentionCoordinator(projectList: model)
    let delivery = FakeNotificationDelivery()
    coordinator.notificationDelivery = delivery
    let muted = SessionAttentionFocus(serverId: "local", sessionId: UUID())
    let focusedWindow = FakeNotificationDelivery()
    let backgroundWindow = FakeNotificationDelivery()
    coordinator.announcementFilter = { session, openSessions in session != muted || openSessions.contains(session) }
    coordinator.updateFocus(
      owner: ObjectIdentifier(focusedWindow), session: SessionAttentionFocus(serverId: "local", sessionId: UUID()))

    func finish() {
      model.onAttentionTransition?(
        SessionAttentionTransition(
          sessionId: muted.sessionId, serverId: muted.serverId,
          old: summary(), new: summary(latest: 1, unread: 1), origin: .liveEvent))
    }
    finish()
    #expect(delivery.delivered.isEmpty)

    coordinator.updateOpenSession(owner: ObjectIdentifier(backgroundWindow), session: muted)
    finish()
    #expect(delivery.delivered.map(\.sessionId) == [muted.sessionId])

    coordinator.updateOpenSession(owner: ObjectIdentifier(backgroundWindow), session: nil)
    finish()
    #expect(delivery.delivered.count == 1)
  }

  @Test("Snapshot catch-ups and manual unread never ping")
  func quietOrigins() async throws {
    let (model, _, _) = try await makeModel()
    let coordinator = SessionAttentionCoordinator(projectList: model)
    let delivery = FakeNotificationDelivery()
    coordinator.notificationDelivery = delivery

    model.onAttentionTransition?(
      SessionAttentionTransition(
        sessionId: UUID(), serverId: "local",
        old: summary(),
        new: summary(latest: 3, unread: 3),
        origin: .snapshot
      ))
    model.onAttentionTransition?(
      SessionAttentionTransition(
        sessionId: UUID(), serverId: "local",
        old: summary(latest: 1, lastSeen: 1),
        new: summary(latest: 2, lastSeen: 1, unread: 1),
        origin: .localMarkUnread
      ))
    #expect(delivery.delivered.isEmpty)
  }

  @Test("Focusing a chat with unseen attention reads it and clears banners")
  func focusReadsUnseenAttention() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/focus-read"))
    let session = ChatSession(
      id: UUID(), projectId: project.id, harnessId: "codex", title: "Focused"
    )
    let (model, fakeServer, fixture) = try await makeModel(sessions: [session], projects: [project])
    await fakeServer.setSessionAttention(id: session.id, latestSequence: 2, lastSeenSequence: 0)
    await fixture.refresh(from: fakeServer)
    #expect(fixture.session(session.id)?.unreadCount == 2)
    let coordinator = SessionAttentionCoordinator(projectList: model)
    let delivery = FakeNotificationDelivery()
    coordinator.notificationDelivery = delivery

    coordinator.updateFocus(
      owner: ObjectIdentifier(delivery),
      session: SessionAttentionFocus(serverId: session.serverId, sessionId: session.id)
    )
    #expect(fixture.session(session.id)?.unreadCount == 0)
    await fixture.flush()
    let requests = await fakeServer.snapshot().readRequests
    #expect(requests.map(\.throughSequence) == [2])
    #expect(delivery.cleared.contains(session.id))
    #expect(delivery.delivered.isEmpty)
  }

  @Test("The newest focus wins over a surface that never released its focus")
  func newestFocusWinsOverStaleSurface() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/focus-stale"))
    let stale = ChatSession(id: UUID(), projectId: project.id, harnessId: "codex", title: "Closed window")
    let current = ChatSession(id: UUID(), projectId: project.id, harnessId: "codex", title: "Open window")
    let (model, fakeServer, fixture) = try await makeModel(sessions: [stale, current], projects: [project])
    await fakeServer.setSessionAttention(id: current.id, latestSequence: 3, lastSeenSequence: 0)
    await fixture.refresh(from: fakeServer)
    let coordinator = SessionAttentionCoordinator(projectList: model)
    let closedWindow = FakeNotificationDelivery()
    let openWindow = FakeNotificationDelivery()
    coordinator.notificationDelivery = openWindow

    coordinator.updateFocus(
      owner: ObjectIdentifier(closedWindow),
      session: SessionAttentionFocus(serverId: stale.serverId, sessionId: stale.id)
    )
    coordinator.updateFocus(
      owner: ObjectIdentifier(openWindow),
      session: SessionAttentionFocus(serverId: current.serverId, sessionId: current.id)
    )

    #expect(coordinator.focusedSession?.sessionId == current.id)
    #expect(fixture.session(current.id)?.unreadCount == 0)
    await fixture.flush()
    #expect(await fakeServer.snapshot().readRequests.map(\.throughSequence) == [3])
  }

  @Test("A surface releasing focus it no longer holds leaves the current focus alone")
  func staleReleaseKeepsCurrentFocus() async throws {
    let (model, _, _) = try await makeModel()
    let coordinator = SessionAttentionCoordinator(projectList: model)
    let previousWindow = FakeNotificationDelivery()
    let currentWindow = FakeNotificationDelivery()
    let current = SessionAttentionFocus(serverId: "local", sessionId: UUID())
    coordinator.updateFocus(
      owner: ObjectIdentifier(previousWindow), session: SessionAttentionFocus(serverId: "local", sessionId: UUID()))
    coordinator.updateFocus(owner: ObjectIdentifier(currentWindow), session: current)

    coordinator.updateFocus(owner: ObjectIdentifier(previousWindow), session: nil)
    #expect(coordinator.focusedSession == current)

    coordinator.updateFocus(owner: ObjectIdentifier(currentWindow), session: nil)
    #expect(coordinator.focusedSession == nil)
  }

  @Test("A finish landing in the focused chat reads instantly with no ping")
  func focusedChatAutoReadsNewFinishes() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/focus-live"))
    let session = ChatSession(
      id: UUID(), projectId: project.id, harnessId: "codex", title: "Focused"
    )
    let (model, fakeServer, fixture) = try await makeModel(sessions: [session], projects: [project])
    let coordinator = SessionAttentionCoordinator(projectList: model)
    let delivery = FakeNotificationDelivery()
    coordinator.notificationDelivery = delivery
    coordinator.updateFocus(
      owner: ObjectIdentifier(delivery),
      session: SessionAttentionFocus(serverId: session.serverId, sessionId: session.id)
    )

    await fakeServer.setSessionAttention(id: session.id, latestSequence: 1, lastSeenSequence: 0)
    await fixture.refresh(from: fakeServer)
    #expect(fixture.session(session.id)?.unreadCount == 0)
    await fixture.flush()
    #expect(fixture.session(session.id)?.unreadCount == 0)
    let requests = await fakeServer.snapshot().readRequests
    #expect(requests.map(\.throughSequence) == [1])
    #expect(delivery.delivered.isEmpty)

    coordinator.updateFocus(owner: ObjectIdentifier(delivery), session: nil)
    model.onAttentionTransition?(
      SessionAttentionTransition(
        sessionId: session.id, serverId: session.serverId,
        old: summary(latest: 1, lastSeen: 1),
        new: summary(latest: 2, lastSeen: 1, unread: 1),
        origin: .liveEvent
      ))
    #expect(delivery.delivered.map(\.kind) == [.finished])
    await fixture.flush()
    let finalRequests = await fakeServer.snapshot().readRequests
    #expect(finalRequests.count == 1)
  }

  @Test("Any transition back to quiet clears delivered banners")
  func readTransitionsClearBanners() async throws {
    let (model, _, _) = try await makeModel()
    let coordinator = SessionAttentionCoordinator(projectList: model)
    let delivery = FakeNotificationDelivery()
    coordinator.notificationDelivery = delivery
    let sessionId = UUID()

    model.onAttentionTransition?(
      SessionAttentionTransition(
        sessionId: sessionId, serverId: "local",
        old: summary(latest: 2, unread: 2, error: true),
        new: summary(latest: 2, lastSeen: 2),
        origin: .liveEvent
      ))
    #expect(delivery.cleared == [sessionId])
    #expect(delivery.delivered.isEmpty)
  }

  @Test("Manually unreading the focused chat holds until focus cycles")
  func manualUnreadOfFocusedChatSticks() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/manual-hold"))
    let session = ChatSession(
      id: UUID(), projectId: project.id, harnessId: "codex", title: "Held"
    )
    let fixture = NavigationFixture()
    await fixture.install(projects: [project], sessions: [session])
    let model = fixture.projectList
    let coordinator = SessionAttentionCoordinator(projectList: model)
    let delivery = FakeNotificationDelivery()
    coordinator.notificationDelivery = delivery
    let focus = SessionAttentionFocus(serverId: session.serverId, sessionId: session.id)
    coordinator.updateFocus(owner: ObjectIdentifier(delivery), session: focus)

    model.markSessionUnread(session.id, serverId: session.serverId)
    #expect(fixture.session(session.id)?.unreadCount == 1)
    #expect(fixture.store.pendingIntents.map(\.intent) == [.markSessionUnread(sessionId: session.id)])

    coordinator.updateFocus(owner: ObjectIdentifier(delivery), session: nil)
    coordinator.updateFocus(owner: ObjectIdentifier(delivery), session: focus)
    #expect(fixture.session(session.id)?.unreadCount == 0)
    let fakeServer = FakeServerClient(
      projects: [serverProject(from: project)], sessions: [serverSession(from: session)])
    fixture.connect(fakeServer)
    await fixture.flush()
    #expect(await fakeServer.snapshot().readRequests.count == 1)
  }
}

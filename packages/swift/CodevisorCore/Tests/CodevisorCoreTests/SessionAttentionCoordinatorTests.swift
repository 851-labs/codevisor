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
    ) async throws -> (ProjectListModel, FakeServerClient) {
        let fakeServer = FakeServerClient(
            projects: projects.map(serverProject(from:)),
            sessions: sessions.map(serverSession(from:))
        )
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            serverClient: fakeServer
        )
        try await waitUntil { model.sessions.count == sessions.count }
        return (model, fakeServer)
    }

    @Test("An unfocused live unread edge pings exactly once")
    func unreadEdgePingsOnce() async throws {
        let (model, _) = try await makeModel()
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

        // Already unread: further finishes stay silent until read.
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
        let (model, _) = try await makeModel()
        let coordinator = SessionAttentionCoordinator(projectList: model)
        let delivery = FakeNotificationDelivery()
        coordinator.notificationDelivery = delivery
        // The user is looking at a chat on the LOCAL machine; the finish
        // lands on a remote one. Fleet notifications must still ping.
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
        let (model, _) = try await makeModel()
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

    @Test("Snapshot catch-ups and manual unread never ping")
    func quietOrigins() async throws {
        let (model, _) = try await makeModel()
        let coordinator = SessionAttentionCoordinator(projectList: model)
        let delivery = FakeNotificationDelivery()
        coordinator.notificationDelivery = delivery

        // App-launch snapshot discovering a finished chat: badge yes, ping no.
        model.onAttentionTransition?(
            SessionAttentionTransition(
                sessionId: UUID(), serverId: "local",
                old: summary(),
                new: summary(latest: 3, unread: 3),
                origin: .snapshot
            ))
        // Manual mark-unread: revision unchanged, so there is no edge.
        model.onAttentionTransition?(
            SessionAttentionTransition(
                sessionId: UUID(), serverId: "local",
                old: summary(latest: 1, lastSeen: 1),
                new: summary(latest: 1, lastSeen: 1, unread: 1),
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
        let (model, fakeServer) = try await makeModel(sessions: [session], projects: [project])
        await fakeServer.setSessionAttention(id: session.id, latestSequence: 2, lastSeenSequence: 0)
        await model.refreshFromServer()
        try await waitUntil {
            model.sessions.first(where: { $0.id == session.id })?.unreadCount == 2
        }
        let coordinator = SessionAttentionCoordinator(projectList: model)
        let delivery = FakeNotificationDelivery()
        coordinator.notificationDelivery = delivery

        coordinator.updateFocus(
            owner: ObjectIdentifier(delivery),
            session: SessionAttentionFocus(serverId: session.serverId, sessionId: session.id)
        )
        try await waitUntilAsync {
            await fakeServer.snapshot().readRequests.count == 1
        }
        let requests = await fakeServer.snapshot().readRequests
        #expect(requests.map(\.throughSequence) == [2])
        #expect(delivery.cleared.contains(session.id))
        #expect(delivery.delivered.isEmpty)
    }

    @Test("A finish landing in the focused chat reads instantly with no ping")
    func focusedChatAutoReadsNewFinishes() async throws {
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/focus-live"))
        let session = ChatSession(
            id: UUID(), projectId: project.id, harnessId: "codex", title: "Focused"
        )
        let (model, fakeServer) = try await makeModel(sessions: [session], projects: [project])
        let coordinator = SessionAttentionCoordinator(projectList: model)
        let delivery = FakeNotificationDelivery()
        coordinator.notificationDelivery = delivery
        coordinator.updateFocus(
            owner: ObjectIdentifier(delivery),
            session: SessionAttentionFocus(serverId: session.serverId, sessionId: session.id)
        )

        // The finish arrives while focused: the model already holds the new
        // revision when the transition fires (snapshot-merge path).
        await fakeServer.setSessionAttention(id: session.id, latestSequence: 1, lastSeenSequence: 0)
        await model.refreshFromServer()
        try await waitUntilAsync {
            await fakeServer.snapshot().readRequests.count == 1
        }
        let requests = await fakeServer.snapshot().readRequests
        #expect(requests.map(\.throughSequence) == [1])
        #expect(delivery.delivered.isEmpty)

        // An unfocused surface (window lost key → publisher sends nil) stops
        // reading and lets pings through again.
        coordinator.updateFocus(owner: ObjectIdentifier(delivery), session: nil)
        model.onAttentionTransition?(
            SessionAttentionTransition(
                sessionId: session.id, serverId: session.serverId,
                old: summary(latest: 1, lastSeen: 1),
                new: summary(latest: 2, lastSeen: 1, unread: 1),
                origin: .liveEvent
            ))
        #expect(delivery.delivered.map(\.kind) == [.finished])
        let finalRequests = await fakeServer.snapshot().readRequests
        #expect(finalRequests.count == 1)
    }

    @Test("Any transition back to quiet clears delivered banners")
    func readTransitionsClearBanners() async throws {
        let (model, _) = try await makeModel()
        let coordinator = SessionAttentionCoordinator(projectList: model)
        let delivery = FakeNotificationDelivery()
        coordinator.notificationDelivery = delivery
        let sessionId = UUID()

        // Read on another device arrives as a live attention update.
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
        let (model, fakeServer) = try await makeModel(sessions: [session], projects: [project])
        let coordinator = SessionAttentionCoordinator(projectList: model)
        let delivery = FakeNotificationDelivery()
        coordinator.notificationDelivery = delivery
        let focus = SessionAttentionFocus(serverId: session.serverId, sessionId: session.id)
        coordinator.updateFocus(owner: ObjectIdentifier(delivery), session: focus)

        model.markSessionUnread(session.id, serverId: session.serverId)
        try await Task.sleep(for: .milliseconds(20))
        // The hold keeps focus from immediately reading the manual flag back.
        #expect(model.sessions.first(where: { $0.id == session.id })?.unreadCount == 1)
        #expect(await fakeServer.snapshot().readRequests.isEmpty)

        // Leaving and returning re-reads it.
        coordinator.updateFocus(owner: ObjectIdentifier(delivery), session: nil)
        coordinator.updateFocus(owner: ObjectIdentifier(delivery), session: focus)
        try await waitUntilAsync {
            await fakeServer.snapshot().readRequests.count == 1
        }
    }
}

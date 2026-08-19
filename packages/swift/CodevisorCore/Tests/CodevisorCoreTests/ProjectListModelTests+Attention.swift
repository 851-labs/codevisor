import Foundation
import Testing
@testable import CodevisorCore

@MainActor
extension ProjectListModelTests {
    @Test("Only presentation of the exact finished response acknowledges attention")
    func exactPresentedResponseOwnsReadAcknowledgement() async throws {
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/visibility-lease"))
        let session = ChatSession(
            id: UUID(), projectId: project.id, harnessId: "codex", title: "Visible"
        )
        let fakeServer = FakeServerClient(
            projects: [serverProject(from: project)],
            sessions: [serverSession(from: session)]
        )
        let responseItemId = UUID()
        await fakeServer.setSessionAttention(
            id: session.id,
            latestSequence: 1,
            lastSeenSequence: 0,
            finishedChatItemId: responseItemId
        )
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            serverClient: fakeServer
        )
        try await waitUntil {
            model.sessions.first(where: { $0.id == session.id })?.unreadCount == 1
        }

        model.acknowledgePresentedAttention(
            session.id,
            serverId: session.serverId,
            target: SessionAttentionTarget(
                sequence: 1,
                kind: .finished,
                chatItemId: UUID()
            )
        )
        try await Task.sleep(for: .milliseconds(10))
        #expect(await fakeServer.snapshot().readRequests.isEmpty)

        model.acknowledgePresentedAttention(
            session.id,
            serverId: session.serverId,
            target: SessionAttentionTarget(
                sequence: 1,
                kind: .finished,
                chatItemId: responseItemId
            )
        )
        try await waitUntil {
            model.sessions.first(where: { $0.id == session.id })?.lastSeenAttentionSequence == 1
        }
        try await waitUntilAsync {
            await fakeServer.snapshot().readRequests.count == 1
        }
        let firstReadRequests = await fakeServer.snapshot().readRequests
        #expect(firstReadRequests.map(\.throughSequence) == [1])

        await fakeServer.setSessionAttention(
            id: session.id,
            latestSequence: 2,
            lastSeenSequence: 1,
            finishedChatItemId: UUID()
        )
        await model.refreshFromServer()
        #expect(model.sessions.first(where: { $0.id == session.id })?.unreadCount == 1)
        let finalReadRequests = await fakeServer.snapshot().readRequests
        #expect(finalReadRequests.count == 1)
    }

    @Test("A delayed read response cannot overwrite newer unread attention")
    func delayedReadResponseDoesNotOverwriteNewerAttention() async throws {
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/stale-read-response"))
        let session = ChatSession(
            id: UUID(), projectId: project.id, harnessId: "codex", title: "Race"
        )
        let fakeServer = FakeServerClient(
            projects: [serverProject(from: project)],
            sessions: [serverSession(from: session)]
        )
        await fakeServer.setSessionAttention(
            id: session.id, latestSequence: 1, lastSeenSequence: 0
        )
        let responseGate = Latch()
        await fakeServer.setReadResponseDelay { await responseGate.wait() }
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            serverClient: fakeServer
        )
        try await waitUntil {
            model.sessions.first(where: { $0.id == session.id })?.latestAttentionSequence == 1
        }

        model.markSessionRead(session.id, serverId: session.serverId, throughSequence: 1)
        try await waitUntilAsync { await fakeServer.snapshot().readRequests.count == 1 }
        await fakeServer.setSessionAttention(
            id: session.id, latestSequence: 2, lastSeenSequence: 1
        )
        await model.refreshFromServer()
        await responseGate.open()
        try await Task.sleep(for: .milliseconds(20))

        let current = model.sessions.first(where: { $0.id == session.id })
        #expect(current?.latestAttentionSequence == 2)
        #expect(current?.lastSeenAttentionSequence == 1)
        #expect(current?.unreadCount == 1)
    }
}

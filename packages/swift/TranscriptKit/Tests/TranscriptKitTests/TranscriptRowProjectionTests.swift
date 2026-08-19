import Foundation
import Testing
import CodevisorProtocol
@testable import TranscriptKit

struct TranscriptRowProjectionTests {
    @Test func finalResponseReceiptMapsOnlyToAssistantPresentationRows() throws {
        let ordinary = AssistantMessage(
            turn: AssistantTurn(entries: [.text(id: "answer", markdown: "Done")])
        )
        let plan = AssistantMessage(
            turn: AssistantTurn(
                entries: [.text(id: "result", markdown: "Implemented")],
                planDocument: "# Plan"
            )
        )

        let rows = try TranscriptRowProjectionCache.project(
            makeInput(settled: [.assistant(ordinary), .assistant(plan)]),
            options: .init(includesConnectingRow: true)
        )

        #expect(rows.first(where: { $0.id == .message(ordinary.id) })?.finishedResponseItemId == ordinary.id)
        #expect(rows.first(where: { $0.id == .plan(plan.id) })?.finishedResponseItemId == nil)
        #expect(rows.first(where: { $0.id == .assistantResult(plan.id) })?.finishedResponseItemId == plan.id)
    }

    @Test func completedActiveRowCarriesItsFinishedResponseIdentity() throws {
        let responseItemId = UUID()
        let completedRows = try TranscriptRowProjectionCache.project(
            makeInput(
                hasActiveItem: true,
                activeFinishedResponseItemId: responseItemId
            ),
            options: .init(includesConnectingRow: true)
        )
        let generatingRows = try TranscriptRowProjectionCache.project(
            makeInput(hasActiveItem: true),
            options: .init(includesConnectingRow: true)
        )

        #expect(
            completedRows.first(where: { $0.id == .active })?.finishedResponseItemId
                == responseItemId
        )
        #expect(generatingRows.first(where: { $0.id == .active })?.finishedResponseItemId == nil)
    }

    @Test func pendingMessageAdoptsTheSettledRowsIdentityWithoutDuplicating() throws {
        let message = UserMessage(text: "Hello")
        let phase = SessionSetupPhase.startingAgent(named: "Codex")
        let input = makeInput(
            settled: [.user(message)],
            pending: message,
            setup: [phase]
        )

        let rows = try TranscriptRowProjectionCache.project(
            input,
            options: .init(includesConnectingRow: true)
        )

        #expect(rows.map(\.id) == [.message(message.id), .setup])
        #expect(rows.filter { $0.id == .message(message.id) }.count == 1)
    }

    @Test func initialConnectionIsAPlatformOptionAndNeverCompetesWithHistoryLoading() throws {
        let connecting = makeInput(status: .connecting("Connecting…"))
        let iosRows = try TranscriptRowProjectionCache.project(
            connecting,
            options: .init(includesConnectingRow: true)
        )
        let macRows = try TranscriptRowProjectionCache.project(
            connecting,
            options: .init(includesConnectingRow: false)
        )
        let loadingRows = try TranscriptRowProjectionCache.project(
            makeInput(isLoadingInitialHistory: true, status: .connecting("Connecting…")),
            options: .init(includesConnectingRow: true)
        )

        #expect(iosRows.map(\.id) == [.connecting])
        #expect(macRows.isEmpty)
        #expect(loadingRows.isEmpty)
    }

    @Test func sessionAndStatusErrorsAreDeduplicated() throws {
        let sameMessage = makeInput(
            sessionError: "Unavailable",
            status: .failed("Unavailable")
        )
        let distinctMessages = makeInput(
            sessionError: "Authentication required",
            status: .failed("Connection failed")
        )

        let sameRows = try TranscriptRowProjectionCache.project(
            sameMessage,
            options: .init(includesConnectingRow: true)
        )
        let distinctRows = try TranscriptRowProjectionCache.project(
            distinctMessages,
            options: .init(includesConnectingRow: true)
        )

        #expect(sameRows.map(\.id) == [.error])
        #expect(distinctRows.map(\.id) == [.error, .statusError])
    }

    @Test func actorCacheReturnsThePreparedSnapshot() async throws {
        let cache = TranscriptRowProjectionCache(capacity: 2)
        let key = TranscriptProjectionKey(
            sessionID: UUID(),
            controllerRevision: 1,
            modelRevision: 2
        )
        let input = makeInput(settled: [.user(UserMessage(text: "Cached"))])
        let options = TranscriptProjectionOptions(includesConnectingRow: true)

        let first = try await cache.rows(for: key, input: input, options: options)
        let second = try await cache.rows(for: key, input: input, options: options)

        #expect(first == second)
        #expect(first.count == 1)
    }

    private func makeInput(
        settled: [ConversationItem] = [],
        pending: UserMessage? = nil,
        hasActiveItem: Bool = false,
        activeFinishedResponseItemId: UUID? = nil,
        setup: [SessionSetupPhase] = [],
        isLoadingInitialHistory: Bool = false,
        sessionError: String? = nil,
        status: TranscriptProjectionInput.ConnectionStatus = .idle
    ) -> TranscriptProjectionInput {
        TranscriptProjectionInput(
            settledConversation: settled,
            pendingUserMessage: pending,
            hasActiveItem: hasActiveItem,
            activeFinishedResponseItemId: activeFinishedResponseItemId,
            setupPhases: setup,
            waitingBackgroundTaskDescription: nil,
            waitingHarnessUpdateName: nil,
            isLoadingInitialHistory: isLoadingInitialHistory,
            serverWaitMessage: nil,
            sessionErrorMessage: sessionError,
            status: status
        )
    }
}

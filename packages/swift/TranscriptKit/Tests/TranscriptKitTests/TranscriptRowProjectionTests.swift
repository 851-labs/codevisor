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

        #expect(
            rows.first(where: { $0.id == .assistantChrome(ordinary.id, .epilogue) })?
                .finishedResponseItemId == ordinary.id
        )
        #expect(rows.first(where: { $0.id == .plan(plan.id) })?.finishedResponseItemId == nil)
        #expect(
            rows.first(where: { $0.id == .assistantChrome(plan.id, .epilogue) })?
                .finishedResponseItemId == plan.id
        )
        #expect(rows.filter { $0.finishedResponseItemId != nil }.count == 2)
    }

    @Test func settledAssistantMarkdownProjectsOneVirtualRowPerBlock() throws {
        let message = AssistantMessage(
            turn: AssistantTurn(
                entries: [
                    .text(
                        id: "answer",
                        markdown: "# Heading\n\nParagraph\n\n- one\n- two"
                    )
                ]
            )
        )

        let rows = try TranscriptRowProjectionCache.project(
            makeInput(settled: [.assistant(message)]),
            options: .init(includesConnectingRow: true)
        )
        let blocks = rows.compactMap { row -> TranscriptMarkdownBlock? in
            if case let .markdownBlock(block) = row.content { block } else { nil }
        }

        #expect(blocks.count == 3)
        #expect(blocks.map(\.ordinal) == [0, 1, 2])
        #expect(blocks.allSatisfy { $0.lifecycle == .settled })
        #expect(rows.dropLast().map(\.spacingAfter) == [10, 10, 14])
        #expect(rows.last?.id == .assistantChrome(message.id, .epilogue))
    }

    @Test func activeAndSettledMarkdownShareBlockLayoutKeys() throws {
        let id = UUID()
        let markdown = "# Heading\n\nParagraph\n\n- one\n- two"
        let activeItem = ConversationItem.assistant(
            AssistantMessage(
                id: id,
                turn: AssistantTurn(
                    entries: [.text(id: "answer", markdown: markdown)],
                    isGenerating: true
                )
            )
        )
        let settledItem = ConversationItem.assistant(
            AssistantMessage(
                id: id,
                turn: AssistantTurn(entries: [.text(id: "answer", markdown: markdown)])
            )
        )

        let activeRows = TranscriptActiveRowProjection.rows(for: activeItem)
        let settledRows = try TranscriptRowProjectionCache.project(
            makeInput(settled: [settledItem]),
            options: .init(includesConnectingRow: true)
        )

        #expect(activeRows.map(\.layoutKey) == settledRows.map(\.layoutKey))
        #expect(activeRows.allSatisfy { $0.id.isActiveRow })
        #expect(
            activeRows.compactMap { row -> TranscriptMarkdownBlock? in
                if case let .markdownBlock(block) = row.content { block } else { nil }
            }.allSatisfy { $0.lifecycle == .receiving }
        )
    }

    @Test func activeBlockRowsReplaceOnlyTheirMatchingProjectionSlot() throws {
        let first = ConversationItem.assistant(
            AssistantMessage(
                turn: AssistantTurn(
                    entries: [.text(id: "answer", markdown: "First\n\nSecond")],
                    isGenerating: true
                )
            )
        )
        let next = ConversationItem.assistant(
            AssistantMessage(turn: AssistantTurn(isGenerating: true))
        )
        let baseRows = try TranscriptRowProjectionCache.project(
            makeInput(active: first),
            options: .init(includesConnectingRow: true)
        )
        let activeRows = TranscriptActiveRowProjection.rows(for: first)
        let staleRows = TranscriptActiveRowProjection.rows(for: next)

        #expect(
            TranscriptActiveRowProjection.replacingActiveSlot(
                in: baseRows,
                with: activeRows
            ).count == activeRows.count
        )
        #expect(
            TranscriptActiveRowProjection.replacingActiveSlot(
                in: baseRows,
                with: staleRows
            ) == baseRows
        )
    }

    @Test func completedActiveRowCarriesItsFinishedResponseIdentity() throws {
        let responseItemId = UUID()
        let completed = ConversationItem.assistant(
            AssistantMessage(
                id: responseItemId,
                turn: AssistantTurn(entries: [.text(id: "answer", markdown: "Done")])
            )
        )
        let generating = ConversationItem.assistant(
            AssistantMessage(turn: AssistantTurn(isGenerating: true))
        )
        let completedRows = try TranscriptRowProjectionCache.project(
            makeInput(active: completed),
            options: .init(includesConnectingRow: true)
        )
        let generatingRows = try TranscriptRowProjectionCache.project(
            makeInput(active: generating),
            options: .init(includesConnectingRow: true)
        )

        #expect(
            completedRows.first(where: { $0.id == .active(responseItemId) })?.finishedResponseItemId
                == responseItemId
        )
        #expect(
            generatingRows.first(where: { $0.id == .active(generating.id) })?.finishedResponseItemId
                == nil
        )
        #expect(
            TranscriptPresentationRow.ID.active(responseItemId).layoutKey
                == TranscriptPresentationRow.ID.message(responseItemId).layoutKey
        )
    }

    @Test func staleActiveProjectionKeepsItsAssistantDuringTheNextTurn() {
        let previous = ConversationItem.assistant(
            AssistantMessage(
                turn: AssistantTurn(entries: [.text(id: "answer", markdown: "Previous response")])
            )
        )
        let next = ConversationItem.assistant(
            AssistantMessage(turn: AssistantTurn(isGenerating: true))
        )

        let resolved = TranscriptActiveItemResolver.resolve(
            projected: previous,
            live: next,
            settled: [previous, .user(UserMessage(text: "Follow up"))]
        )

        #expect(resolved == previous)
    }

    @Test func activeIdentityAdoptionKeepsRenderingTheLiveAssistant() {
        let local = ConversationItem.assistant(
            AssistantMessage(turn: AssistantTurn(isGenerating: true))
        )
        let canonical = ConversationItem.assistant(
            AssistantMessage(
                turn: AssistantTurn(
                    entries: [.text(id: "answer", markdown: "Streaming")],
                    isGenerating: true
                )
            )
        )

        let resolved = TranscriptActiveItemResolver.resolve(
            projected: local,
            live: canonical,
            settled: []
        )

        #expect(resolved == canonical)
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
        active: ConversationItem? = nil,
        setup: [SessionSetupPhase] = [],
        isLoadingInitialHistory: Bool = false,
        sessionError: String? = nil,
        status: TranscriptProjectionInput.ConnectionStatus = .idle
    ) -> TranscriptProjectionInput {
        TranscriptProjectionInput(
            settledConversation: settled,
            pendingUserMessage: pending,
            activeItem: active,
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

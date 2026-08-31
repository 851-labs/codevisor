import CodevisorProtocol
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptComplexBlockQuoteProjectionTests {
    @Test func proseOnlyBlockQuoteKeepsTheSingleTextKitRow() throws {
        let message = AssistantMessage(
            turn: AssistantTurn(
                entries: [
                    .text(
                        id: "answer",
                        markdown: "> Quoted prose\n>\n> - one\n> - two"
                    )
                ]
            )
        )

        let chunks = try TranscriptRowProjectionCache.project(
            makeInput(settled: [.assistant(message)]),
            options: .init(includesConnectingRow: true)
        ).compactMap { row -> TranscriptMarkdownChunk? in
            if case let .markdownChunk(chunk) = row.content { chunk } else { nil }
        }

        #expect(chunks.count == 1)
        #expect(chunks.first?.fragment == nil)
        #expect(chunks.first?.blocks.first?.id.hasPrefix("quote:") == true)
    }

    @Test func complexBlockQuoteProjectsBoundedStructuralLeafRows() throws {
        let id = UUID()
        let markdown = """
            > # Heading inside a quote
            >
            > 1. Ordered item with **bold**
            > 2. Ordered item with embedded content:
            >
            >    ```json
            >    {"value": true}
            >    ```
            >
            >    | A | B |
            >    |---|---|
            >    | 1 | 2 |
            >
            >    - [x] Done
            >    - [ ] Not done
            """
        let settled = ConversationItem.assistant(
            AssistantMessage(
                id: id,
                turn: AssistantTurn(entries: [.text(id: "answer", markdown: markdown)])
            )
        )
        let active = ConversationItem.assistant(
            AssistantMessage(
                id: id,
                turn: AssistantTurn(
                    entries: [.text(id: "answer", markdown: markdown)],
                    isGenerating: true
                )
            )
        )

        let settledRows = try TranscriptRowProjectionCache.project(
            makeInput(settled: [settled]),
            options: .init(includesConnectingRow: true)
        ).filter {
            if case .markdownChunk = $0.content { true } else { false }
        }
        let activeRows = TranscriptActiveRowProjection.rows(for: active).filter {
            if case .markdownChunk = $0.content { true } else { false }
        }
        let chunks = settledRows.compactMap { row -> TranscriptMarkdownChunk? in
            if case let .markdownChunk(chunk) = row.content { chunk } else { nil }
        }

        #expect(chunks.count >= 4)
        #expect(chunks.allSatisfy { $0.fragment?.quoteDepth == 1 })
        #expect(chunks.map(\.ordinal).allSatisfy { $0 == 0 })
        #expect(Set(settledRows.map(\.layoutKey)).count == settledRows.count)
        #expect(activeRows.map(\.layoutKey) == settledRows.map(\.layoutKey))
        #expect(settledRows.dropLast().allSatisfy { $0.spacingAfter == 0 })
        #expect(settledRows.last?.spacingAfter == 14)

        let code = chunks.first { $0.blocks.first?.id.hasPrefix("code:") == true }
        let table = chunks.first { $0.blocks.first?.id.hasPrefix("table:") == true }
        let markerTexts = chunks.flatMap { $0.fragment?.listMarkers ?? [] }.map(\.text)
        #expect(code?.blocks.count == 1)
        #expect(code?.fragment?.listDepth == 1)
        #expect(table?.blocks.count == 1)
        #expect(table?.fragment?.listDepth == 1)
        #expect(markerTexts.contains("1."))
        #expect(markerTexts.contains("2."))
    }

    @Test func complexTopLevelListProjectsNativeLeafRows() throws {
        let message = AssistantMessage(
            turn: AssistantTurn(
                entries: [
                    .text(
                        id: "answer",
                        markdown: """
                            1. First item
                            2. Item with code

                               ```swift
                               let value = 42
                               ```

                               | Name | Value |
                               | --- | ---: |
                               | answer | 42 |
                            """
                    )
                ]
            )
        )

        let chunks = try TranscriptRowProjectionCache.project(
            makeInput(settled: [.assistant(message)]),
            options: .init(includesConnectingRow: true)
        ).compactMap { row -> TranscriptMarkdownChunk? in
            if case let .markdownChunk(chunk) = row.content { chunk } else { nil }
        }

        #expect(chunks.count >= 3)
        #expect(chunks.allSatisfy { $0.fragment?.quoteDepth == 0 })
        #expect(chunks.contains { $0.blocks.first?.id.hasPrefix("code:") == true })
        #expect(chunks.contains { $0.blocks.first?.id.hasPrefix("table:") == true })
        #expect(chunks.flatMap { $0.fragment?.listMarkers ?? [] }.contains { $0.text == "2." })
    }

    private func makeInput(settled: [ConversationItem]) -> TranscriptProjectionInput {
        TranscriptProjectionInput(
            settledConversation: settled,
            pendingUserMessage: nil,
            activeItem: nil,
            setupPhases: [],
            waitingBackgroundTaskDescription: nil,
            waitingHarnessUpdateName: nil,
            isLoadingInitialHistory: false,
            serverWaitMessage: nil,
            sessionErrorMessage: nil,
            status: .idle
        )
    }
}

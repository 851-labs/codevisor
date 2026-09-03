import Foundation
import Testing
import ACPKit
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
    #expect(
      rows.first(where: { $0.id == .planHeader(plan.id) })?.finishedResponseItemId == nil
    )
    #expect(
      rows.first(where: { $0.id == .assistantChrome(plan.id, .epilogue) })?
        .finishedResponseItemId == plan.id
    )
    #expect(rows.filter { $0.finishedResponseItemId != nil }.count == 2)
  }

  @Test func settledAssistantMarkdownChunksCompatibleTextBlocks() throws {
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
    let chunks = rows.compactMap { row -> TranscriptMarkdownChunk? in
      if case let .markdownChunk(chunk) = row.content { chunk } else { nil }
    }

    #expect(chunks.count == 1)
    #expect(chunks.map(\.ordinal) == [0])
    #expect(chunks.map { $0.blocks.count } == [3])
    #expect(chunks.allSatisfy { $0.lifecycle == .settled })
    #expect(rows.dropLast().map(\.spacingAfter) == [14])
    #expect(rows.last?.id == .assistantChrome(message.id, .epilogue))
  }

  @Test func proseChunksAreHeightBoundedAndKeepStablePrefixIdentities() throws {
    let id = UUID()
    let firstNine = (1...9).map { "Paragraph \($0)" }.joined(separator: "\n\n")
    let firstTen = firstNine + "\n\nParagraph 10"

    func rows(for markdown: String) throws -> [TranscriptPresentationRow] {
      try TranscriptRowProjectionCache.project(
        makeInput(
          settled: [
            .assistant(
              AssistantMessage(
                id: id,
                turn: AssistantTurn(
                  entries: [.text(id: "answer", markdown: markdown)]
                )
              )
            )
          ]
        ),
        options: .init(includesConnectingRow: true)
      ).filter {
        if case .markdownChunk = $0.content { true } else { false }
      }
    }

    let nineRows = try rows(for: firstNine)
    let tenRows = try rows(for: firstTen)
    let tenChunks = tenRows.compactMap { row -> TranscriptMarkdownChunk? in
      if case let .markdownChunk(chunk) = row.content { chunk } else { nil }
    }

    #expect(nineRows.count == 1)
    #expect(tenChunks.map { $0.blocks.count } == [9, 1])
    #expect(tenChunks.map(\.ordinal) == [0, 9])
    #expect(nineRows[0].layoutKey == tenRows[0].layoutKey)
    #expect(nineRows[0].measurementRevision == tenRows[0].measurementRevision)
  }

  @Test func longProseSplitsBeforeTheHardBlockCountLimit() throws {
    let paragraph = String(repeating: "wrapped prose ", count: 55)
    let message = AssistantMessage(
      turn: AssistantTurn(
        entries: [.text(id: "answer", markdown: "\(paragraph)\n\n\(paragraph)")]
      )
    )

    let chunks = try TranscriptRowProjectionCache.project(
      makeInput(settled: [.assistant(message)]),
      options: .init(includesConnectingRow: true)
    ).compactMap { row -> TranscriptMarkdownChunk? in
      if case let .markdownChunk(chunk) = row.content { chunk } else { nil }
    }

    #expect(chunks.map { $0.blocks.count } == [1, 1])
    #expect(chunks.map(\.ordinal) == [0, 1])
  }

  @Test func codeBlocksRemainIndependentBetweenProseChunks() throws {
    let message = AssistantMessage(
      turn: AssistantTurn(
        entries: [
          .text(
            id: "answer",
            markdown: "Before one\n\nBefore two\n\n```swift\nlet value = 1\n```\n\nAfter one\n\nAfter two"
          )
        ]
      )
    )

    let rows = try TranscriptRowProjectionCache.project(
      makeInput(settled: [.assistant(message)]),
      options: .init(includesConnectingRow: true)
    )
    let chunks = rows.compactMap { row -> TranscriptMarkdownChunk? in
      if case let .markdownChunk(chunk) = row.content { chunk } else { nil }
    }

    #expect(chunks.map(\.ordinal) == [0, 2, 3])
    #expect(chunks.map { $0.blocks.count } == [2, 1, 2])
    #expect(chunks[1].blocks.first?.id.hasPrefix("code:") == true)
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
      activeRows.compactMap { row -> TranscriptMarkdownChunk? in
        if case let .markdownChunk(chunk) = row.content { chunk } else { nil }
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

  @Test func freshActiveTurnUsesItsKnownActivityHeightBeforeBlockProjection() throws {
    let active = ConversationItem.assistant(
      AssistantMessage(turn: AssistantTurn(isGenerating: true))
    )

    let baseRows = try TranscriptRowProjectionCache.project(
      makeInput(active: active),
      options: .init(includesConnectingRow: true)
    )
    let aggregate = try #require(baseRows.first(where: { $0.id.isActiveRow }))
    let precise = try #require(TranscriptActiveRowProjection.rows(for: active).first)

    #expect(aggregate.estimatedHeight == 32)
    #expect(precise.estimatedHeight == 32)
  }

  @Test func onlyBlockProjectedActiveRowsOwnPreciseSendGeometry() throws {
    let active = ConversationItem.assistant(
      AssistantMessage(turn: AssistantTurn(isGenerating: true))
    )
    let baseRows = try TranscriptRowProjectionCache.project(
      makeInput(active: active),
      options: .init(includesConnectingRow: true)
    )
    let aggregate = try #require(baseRows.first(where: { $0.id.isActiveRow }))
    let precise = try #require(TranscriptActiveRowProjection.rows(for: active).first)

    #expect(aggregate.id.isActiveRow)
    #expect(!aggregate.id.isPreciselyProjectedActiveRow)
    #expect(precise.id.isActiveRow)
    #expect(precise.id.isPreciselyProjectedActiveRow)
  }

  @Test func planMarkdownUsesTheSameBlockRowsWhileActiveAndSettled() throws {
    let id = UUID()
    let markdown = "# Plan\n\n1. First\n2. Second\n\nVerify the result."
    let active = ConversationItem.assistant(
      AssistantMessage(
        id: id,
        turn: AssistantTurn(isGenerating: true, planDocument: markdown)
      )
    )
    let settled = ConversationItem.assistant(
      AssistantMessage(id: id, turn: AssistantTurn(planDocument: markdown))
    )

    let activePlanRows = TranscriptActiveRowProjection.rows(for: active).filter(\.isPlanSlice)
    let settledPlanRows = try TranscriptRowProjectionCache.project(
      makeInput(settled: [settled]),
      options: .init(includesConnectingRow: true)
    ).filter(\.isPlanSlice)

    #expect(activePlanRows.count == 2)
    #expect(activePlanRows.map(\.layoutKey) == settledPlanRows.map(\.layoutKey))
    #expect(activePlanRows.allSatisfy { $0.spacingAfter == 0 })
    #expect(activePlanRows.first?.id == .activePlanHeader(id))
    #expect(settledPlanRows.first?.id == .planHeader(id))
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

private extension TranscriptPresentationRow {
  var isPlanSlice: Bool {
    switch content {
    case .planHeader:
      true
    case let .markdownChunk(chunk):
      chunk.container == .planDocument
    default:
      false
    }
  }
}

extension TranscriptRowProjectionTests {
  private func chunks(for markdown: String) throws -> [TranscriptMarkdownChunk] {
    let message = AssistantMessage(
      id: UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!,
      turn: AssistantTurn(entries: [.text(id: "answer", markdown: markdown)])
    )
    let rows = try TranscriptRowProjectionCache.project(
      makeInput(settled: [.assistant(message)]),
      options: .init(includesConnectingRow: true)
    )
    return rows.compactMap { row in
      if case let .markdownChunk(chunk) = row.content { chunk } else { nil }
    }
  }

  /// Every token of a streaming answer must project its prose and list into
  /// the same row. A list that moved into a row of its own when a new `- `
  /// marker arrived and merged back a token later replayed the whole list's
  /// reveal animation on every item.
  @Test func streamingListStaysInTheProseRowAcrossItemBoundaries() throws {
    let prefix = "This repo is Codevisor.\n\nIts main pieces are:\n\n"
    let sources = [
      prefix + "- ",
      prefix + "- `apps/macos` — native app",
      prefix + "- `apps/macos` — native app\n- ",
      prefix + "- `apps/macos` — native app\n- `apps/ios` — companion",
      prefix + "- `apps/macos` — native app\n\n- `apps/ios` — loose list",
      prefix + "- `apps/macos` — native app\n  - nested item",
    ]
    for source in sources {
      let chunks = try chunks(for: source)
      #expect(chunks.count == 1, "expected one row for \(source.debugDescription)")
      #expect(chunks.first?.ordinal == 0)
      #expect(chunks.first?.blocks.count == 3, "expected prose + list in one row for \(source.debugDescription)")
    }
  }

  @Test func listsWithCodeBlocksStillFragmentStructurally() throws {
    let chunks = try chunks(for: "Intro\n\n- item\n\n  ```swift\n  let x = 1\n  ```\n")
    #expect(chunks.count > 1)
  }
}

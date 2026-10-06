import CodevisorProtocol
import Foundation
import MarkdownCore
import Testing
@testable import TranscriptKit

/// Rows split from one Markdown document sit flush; each row draws the gap
/// its first block takes from the block above it, so a paragraph gap is the
/// same whether or not a row boundary falls there.
struct TranscriptMarkdownRowSpacingTests {
  @Test func rowsOfOneDocumentCarryTheBlockAboveThem() throws {
    let paragraph = String(repeating: "A long transcript sentence that wraps across lines. ", count: 8)
    let markdown = (1...8).map { $0 == 4 ? "## Section\n\n\(paragraph)" : paragraph }.joined(separator: "\n\n")
    let rows = try markdownRows(markdown)
    let chunks = rows.compactMap(\.chunk)
    try #require(chunks.count > 1)

    #expect(chunks[0].precedingRole == nil)
    for (previous, chunk) in zip(chunks, chunks.dropFirst()) {
      #expect(chunk.precedingRole == previous.blocks.last?.role)
    }
    #expect(rows.dropLast().allSatisfy { $0.spacingAfter == 0 })
    // Copying across the boundary still yields a paragraph break.
    #expect(TranscriptSelectionText.rowSeparator(previous: rows[0], current: rows[1]) == "\n\n")
  }

  @Test func fragmentsCarryTheirOwnSpacing() throws {
    let markdown = """
      1. Run the build:

         ```sh
         bun run build
         ```

      2. Then check the output

      > # Quoted heading
      >
      > ```sh
      > echo quoted
      > ```
      """
    let rows = try markdownRows(markdown)
    let fragments = rows.compactMap(\.chunk).compactMap(\.fragment)
    try #require(fragments.count == 5)

    // Inside a list every row is spaced like an item, and continuation rows
    // copy as lines of the same list.
    #expect(fragments[0].trailingSpacing == .listItem)
    #expect(fragments[1].trailingSpacing == .listItem)
    #expect(TranscriptSelectionText.rowSeparator(previous: rows[0], current: rows[1]) == "\n")
    // The quote starts a new block, and the heading's spacing rule still
    // applies between its leaf rows.
    #expect(rows[3].chunk?.precedingRole == .list)
    #expect(fragments[3].trailingSpacing == .block(after: .heading(level: 1), before: .codeBlock))
  }

  private func markdownRows(_ markdown: String) throws -> [TranscriptPresentationRow] {
    let message = AssistantMessage(turn: AssistantTurn(entries: [.text(id: "answer", markdown: markdown)]))
    return try TranscriptRowProjectionCache.project(
      TranscriptProjectionInput(
        settledConversation: [.assistant(message)],
        pendingUserMessage: nil,
        activeItem: nil,
        setupPhases: [],
        waitingBackgroundTaskDescription: nil,
        waitingHarnessUpdateName: nil,
        isLoadingInitialHistory: false,
        serverWaitMessage: nil,
        sessionErrorMessage: nil,
        status: .idle
      ),
      options: .init(includesConnectingRow: true)
    ).filter { $0.chunk != nil }
  }
}

private extension TranscriptPresentationRow {
  var chunk: TranscriptMarkdownChunk? {
    if case let .markdownChunk(chunk) = content { chunk } else { nil }
  }
}

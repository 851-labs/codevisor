import ACPKit
import Foundation
import MarkdownCore
import StreamMarkdown
import Testing
import TranscriptKit
@testable import CodevisorUI

@Suite("Transcript find")
struct TranscriptFindEngineTests {
  @MainActor
  @Test("Find searches the final response and skips worked narration")
  func searchesFinalResponseOnly() async throws {
    var turn = AssistantTurn(isGenerating: false)
    turn.entries = [
      .text(id: "t0", markdown: "Looking for the config file first."),
      .text(id: "t1", markdown: "The config is in `config.yaml`.\n\n```yaml\nconfig: true\n```"),
    ]
    turn.textPhases["t0"] = .commentary
    turn.textPhases["t1"] = .final
    let rows = TranscriptActiveRowProjection.rows(
      for: .assistant(AssistantMessage(id: UUID(), turn: turn)))
    let worked = rows.filter { row in
      guard case let .markdownChunk(chunk) = row.content else { return false }
      return chunk.container == .assistantWorked
    }
    try #require(!worked.isEmpty, "the worked narration must be projected for this test to mean anything")

    let engine = TranscriptFindEngine()
    #expect(await engine.search("CONFIG", rows: rows, firstVisibleRow: 0, theme: .default).value)

    // Prose ("config is", "config.yaml") and the code block; none from the narration.
    #expect(engine.results.count == 3)
    #expect(engine.results.rows.allSatisfy { row in !worked.contains { $0.layoutKey == row.rowKey } })
  }

  @MainActor
  @Test("A mounted row's matches are numbered through its surfaces in order")
  func highlightsFollowSurfaceOrder() async throws {
    let text = "alpha beta alpha"
    let row = TranscriptVirtualRow(
      id: .bottomSpacer,
      content: .markdownChunk(
        TranscriptMarkdownChunk(
          messageID: UUID(), sourceID: "s", ordinal: 0,
          blocks: [.paragraph(MarkdownText(text)), .codeBlock(language: nil, code: "alpha", isComplete: true)],
          documentSource: text, lifecycle: .settled, container: .assistantResponse
        )),
      estimatedHeight: 10
    )
    let engine = TranscriptFindEngine()
    #expect(await engine.search("alpha", rows: [row], firstVisibleRow: 0, theme: .default).value)
    engine.step(by: 2)

    let highlights = engine.highlights(forRow: row.layoutKey, surfaceTexts: [text, "alpha"])
    #expect(
      highlights[0]
        == TranscriptFindHighlights(ranges: [.init(location: 0, length: 5), .init(location: 11, length: 5)]))
    #expect(highlights[1] == TranscriptFindHighlights(ranges: [.init(location: 0, length: 5)], currentIndex: 0))
  }

  @MainActor
  @Test("Typing ahead of the background count never shows a stale query, and early steps still land")
  func supersededSearchesNeverPublish() async throws {
    let text = "alpha beta alpha beta"
    let row = TranscriptVirtualRow(
      id: .bottomSpacer,
      content: .markdownChunk(
        TranscriptMarkdownChunk(
          messageID: UUID(), sourceID: "s", ordinal: 0, blocks: [.paragraph(MarkdownText(text))],
          documentSource: text, lifecycle: .settled, container: .assistantResponse
        )),
      estimatedHeight: 10
    )
    let engine = TranscriptFindEngine()
    let stale = engine.search("alpha", rows: [row], firstVisibleRow: 0, theme: .default)
    let latest = engine.search("beta", rows: [row], firstVisibleRow: 0, theme: .default)
    // Return pressed before the count arrives moves past the first match.
    #expect(!engine.step(by: 1))

    #expect(await stale.value == false)
    #expect(await latest.value)
    #expect(engine.query == "beta")
    #expect(engine.results.count == 2)
    #expect(engine.results.currentIndex == 1)
  }
}

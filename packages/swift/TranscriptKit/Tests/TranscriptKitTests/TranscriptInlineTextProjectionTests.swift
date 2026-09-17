import ACPKit
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptInlineTextProjectionTests {
  @Test func responseReplacesPreviewWithStableVirtualTextRanges() throws {
    let resource = try JSONDecoder().decode(
      ToolDetailResource.self,
      from: Data(
        """
        {"itemId":"item","entryKey":"answer","fields":[{"name":"text","encoding":"text","revision":9,"generation":1,"sizeBytes":280000,"pageCount":18}]}
        """.utf8))
    var turn = AssistantTurn(entries: [.text(id: "answer", markdown: "Preview")], isGenerating: false)
    turn.textStates[":answer"] = TranscriptTextState(generation: 1, revision: 9, resource: resource)
    let message = AssistantMessage(id: UUID(), turn: turn)
    var rows: [TranscriptPresentationRow] = []
    TranscriptAssistantRowProjection.appendSettled(.assistant(message), waitingOnBackgroundTask: nil, to: &rows)
    let pages = rows.compactMap { row -> TranscriptInlineTextPage? in
      if case let .inlineText(page) = row.content { return page }
      return nil
    }
    #expect(pages.map(\.position) == [0, 8, 16])
    #expect(pages.map(\.preview) == ["Preview", "", ""])
    #expect(pages.map(\.isLast) == [false, false, true])
    var updated = pages
    for index in updated.indices { updated[index].resource.fields[0].revision += 1 }
    #expect(updated[0] == pages[0])
    #expect(updated[1] == pages[1])
    #expect(updated[2] != pages[2])
    #expect(updated[0].displayRevision == pages[0].displayRevision)
    updated[0].resource.fields[0].generation = 2
    #expect(updated[0] != pages[0])
    #expect(
      !rows.contains {
        if case .markdownChunk = $0.content { return true }; return false
      })
    #expect(Set(rows.map(\.layoutKey)).count == rows.count)
    #expect(TranscriptActiveRowProjection.rows(for: .assistant(message)).map(\.layoutKey) == rows.map(\.layoutKey))
  }
}

import Foundation
import MarkdownCore
import Testing
@testable import TranscriptKit

struct TranscriptMarkdownInvalidationTests {
  private let messageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

  @Test func movingAnAnswerIntoWorkedContentPreservesAnimationIdentity() throws {
    let first = TranscriptEntry.text(id: "first", markdown: "Already visible text")
    func project(_ entries: [TranscriptEntry]) -> [TranscriptMarkdownChunk] {
      TranscriptActiveRowProjection.rows(
        for: .assistant(
          .init(
            id: messageID, turn: .init(entries: entries, isGenerating: true)
          ))
      ).compactMap {
        if case let .markdownChunk(chunk) = $0.content { chunk } else { nil }
      }
    }
    let before = try #require(project([first]).first)
    let after = project([first, .text(id: "next", markdown: "New part")])
    let moved = try #require(after.first)
    #expect(before.container == .assistantResponse)
    #expect(moved.container == .assistantWorked)
    #expect(before.sourceID != moved.sourceID)
    #expect(before.animationStreamID == moved.animationStreamID)
    #expect(before.animationGroupID == moved.animationGroupID)
    #expect(Set(after.map(\.animationStreamID)).count == after.count)
  }

  private func chunk(_ block: MarkdownBlock, source: String = "source") -> TranscriptMarkdownChunk {
    .init(
      messageID: messageID, sourceID: "answer", ordinal: 0, blocks: [block],
      documentSource: source, lifecycle: .receiving, container: .assistantResponse)
  }

  @Test func unrelatedSourceAppendDoesNotInvalidateRenderedPrefix() {
    let before = chunk(.paragraph("Unchanged prefix"), source: "Unchanged prefix\n\nNext")
    let after = chunk(.paragraph("Unchanged prefix"), source: "Unchanged prefix\n\nNext words")
    #expect(before == after)
    #expect(before.measurementRevision == after.measurementRevision)
  }

  @Test func sameSizeTableEditInvalidatesMeasurement() {
    let before = chunk(.table(headers: ["Name"], alignments: [.leading], rows: [["short"]]))
    let after = chunk(.table(headers: ["Name"], alignments: [.leading], rows: [["Much longer wrapping cell"]]))
    #expect(before != after)
    #expect(before.measurementRevision != after.measurementRevision)
  }

  @Test func styleEditInvalidatesMeasurement() {
    let before = chunk(.paragraph(MarkdownText("same words")))
    let after = chunk(.paragraph(MarkdownText(spans: [.strong([.text("same words")])])))
    #expect(before.measurementRevision != after.measurementRevision)
  }
}

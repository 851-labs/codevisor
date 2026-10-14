import ACPKit
import Foundation
import Testing

@testable import TranscriptKit

@Suite("Blank text spans never become the answer")
struct TranscriptBlankTextSpanTests {
  private func patch(
    _ text: String,
    offset: Int = 0,
    stateRevision: Int = 1,
    messageId: String = "m1"
  ) -> SessionUpdate {
    .agentMessagePatch(
      AgentMessagePatch(
        messageId: messageId, text: text, offset: offset,
        totalLength: offset + text.utf16.count, generation: 0, stateRevision: stateRevision))
  }

  @Test("A zero-length span is never materialized and the indicator survives")
  func emptySpan() {
    var turn = AssistantTurn(isGenerating: true)
    TranscriptReducer.apply(patch(""), to: &turn)
    #expect(turn.entries.isEmpty)
    #expect(turn.finalText == nil)
    #expect(turn.showsActivityIndicator)
  }

  @Test("A whitespace-only span is stored but never counts as content")
  func whitespaceSpan() {
    var turn = AssistantTurn(isGenerating: true)
    TranscriptReducer.apply(patch("\n"), to: &turn)
    #expect(turn.entries == [.text(id: "acp:m1", markdown: "\n")])
    #expect(turn.finalText == nil)
    #expect(turn.showsActivityIndicator)
    #expect(turn.workedItems.isEmpty)
  }

  @Test("A blank-only turn keeps the 32pt activity reservation, not a 320pt answer slot")
  func blankTurnKeepsActivityHeight() {
    var turn = AssistantTurn(isGenerating: true)
    TranscriptReducer.apply(patch("\n"), to: &turn)
    let item = ConversationItem.assistant(AssistantMessage(turn: turn))
    #expect(
      TranscriptAssistantRowProjection.activeFallbackEstimatedHeight(for: item)
        == TranscriptAssistantRowProjection.activityRowEstimatedHeight)
  }

  @Test("Text continuing after a blank opener still accumulates at the right offset")
  func blankOpenerKeepsOffsetsAligned() {
    var turn = AssistantTurn(isGenerating: true)
    TranscriptReducer.apply(patch("\n"), to: &turn)
    TranscriptReducer.apply(patch("Hi", offset: 1, stateRevision: 2), to: &turn)
    #expect(turn.entries == [.text(id: "acp:m1", markdown: "\nHi")])
  }

  @Test("Real content takes over as the answer and retires the indicator")
  func realContentWins() {
    var turn = AssistantTurn(isGenerating: true)
    TranscriptReducer.apply(patch(""), to: &turn)
    TranscriptReducer.apply(patch("The answer is 42.", stateRevision: 2), to: &turn)
    #expect(turn.finalText == .text(id: "acp:m1", markdown: "The answer is 42."))
    #expect(!turn.showsActivityIndicator)
  }

  @Test("A blank span never displaces a real earlier answer")
  func blankDoesNotDisplaceEarlierAnswer() {
    var turn = AssistantTurn(isGenerating: true)
    TranscriptReducer.apply(patch("Done.", messageId: "m1"), to: &turn)
    TranscriptReducer.apply(patch("\n", messageId: "m2"), to: &turn)
    #expect(turn.finalText == .text(id: "acp:m1", markdown: "Done."))
  }
}

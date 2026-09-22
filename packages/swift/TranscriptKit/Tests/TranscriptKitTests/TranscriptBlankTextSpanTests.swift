import ACPKit
import Foundation
import Testing

@testable import TranscriptKit

/// A blank text span must never be mistaken for the turn's answer.
///
/// Harnesses legitimately stream spans with nothing visible in them: Claude
/// retro-tags a preamble with a zero-length chunk, and a message can open
/// with a bare newline. Live text reaches the client as `agentMessagePatch`
/// (the server rewrites every chunk into one), and that path used to
/// materialize such a span unconditionally. `finalText` then went non-nil,
/// which retires `showsActivityIndicator` — so the shimmer disappeared and
/// what replaced it rendered nothing, leaving reserved blank space until the
/// first real token. Codex never hit this because it keeps `isThinking` set,
/// which short-circuits the gate before `finalText` is consulted.
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
    // Kept in `entries`: its length is what later patch offsets are measured
    // against, so dropping it would desync the stream.
    #expect(turn.entries == [.text(id: "acp:m1", markdown: "\n")])
    // …but invisible to every presentation query.
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

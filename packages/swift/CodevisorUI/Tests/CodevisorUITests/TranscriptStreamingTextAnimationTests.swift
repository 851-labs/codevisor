import ACPKit
import CodevisorCore
import Foundation
import StreamMarkdown
import Testing
import TranscriptKit
@testable import CodevisorUI

@Suite("Transcript streaming text identity")
struct TranscriptStreamingTextAnimationTests {
  @MainActor
  @Test("An uncached active turn settles projected worked details and animates later entries")
  func projectedWorkedRestoration() throws {
    let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    var turn = AssistantTurn(
      isGenerating: true,
      deferredDetailItemId: "detail",
      hasDeferredWorkedDetails: true,
      detailRevision: 7
    )
    let compact = ConversationItem.assistant(AssistantMessage(id: id, turn: turn))
    let registry = StreamingTextAnimationRegistry()

    func observe(_ item: ConversationItem) -> [String] {
      let streams = TranscriptActiveRowProjection.rows(for: item).compactMap { row -> String? in
        guard case let .markdownChunk(chunk) = row.content,
          chunk.lifecycle == .receiving
        else { return nil }
        return row.layoutKey
      }
      registry.observeProjectedStreams(
        streams,
        animatesNewStreams: true,
        restorationID: TranscriptStreamingTextIdentity.restorationID(for: item)
      )
      return streams
    }

    #expect(observe(compact).isEmpty)
    turn.entries = [.text(id: "t0", markdown: "Existing work")]
    turn.textPhases["t0"] = .commentary
    turn.deferredDetailItemId = nil
    turn.hasDeferredWorkedDetails = false
    turn.hasHydratedWorkedDetails = true
    let hydrated = ConversationItem.assistant(AssistantMessage(id: id, turn: turn))
    let restored = try #require(observe(hydrated).first)
    #expect(!registry.presentation.claimInitialAnimation(for: restored))

    turn.entries.append(.text(id: "t1", markdown: "New work"))
    turn.textPhases["t1"] = .commentary
    let live = ConversationItem.assistant(AssistantMessage(id: id, turn: turn))
    let newStream = try #require(observe(live).first { $0 != restored })
    #expect(registry.presentation.claimInitialAnimation(for: newStream))
    #expect(TranscriptStreamingTextIdentity.restorationID(for: compact) == nil)
    #expect(
      TranscriptStreamingTextIdentity.restorationID(for: hydrated)
        == TranscriptStreamingTextIdentity.restorationID(for: live)
    )

    let anotherTurn = ConversationItem.assistant(
      AssistantMessage(id: UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, turn: turn)
    )
    #expect(
      TranscriptStreamingTextIdentity.restorationID(for: anotherTurn)
        != TranscriptStreamingTextIdentity.restorationID(for: hydrated)
    )
  }

  @Test("Initial settlement includes main and separately namespaced subagent text")
  func settledStreamIDs() {
    let turnID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    var turn = AssistantTurn(entries: [.text(id: "t0", markdown: "Main")])
    turn.subagents["agent-1"] = SubagentTranscript(
      entries: [.text(id: "t0", markdown: "Child")]
    )

    let ids = Set(
      TranscriptStreamingTextIdentity.settledStreamIDs(
        turn: turn,
        turnID: turnID
      )
    )

    #expect(
      ids == [
        "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE:main:t0",
        "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE:main:t0:0",
        "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE:subagent:agent-1:t0",
      ])
  }

  @Test("Navigation settles every mounted Markdown slice of the existing final answer")
  func settledResponseSegments() {
    let turnID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let attachment = Attachment(
      fileId: "file-1",
      name: "plot.png",
      mimeType: "image/png",
      sizeBytes: 42,
      kind: .image
    )
    let turn = AssistantTurn(
      entries: [
        .text(
          id: "answer",
          markdown: "Before ![plot](https://attachments.codevisor.invalid/file-1) after"
        )
      ],
      attachments: [attachment],
      isGenerating: true
    )

    let ids = Set(
      TranscriptStreamingTextIdentity.settledStreamIDs(
        turn: turn,
        turnID: turnID
      )
    )

    #expect(
      ids.contains(
        TranscriptStreamingTextIdentity.mainResponseSegment(
          turnID: turnID,
          entryID: "answer",
          segmentIndex: 0
        )))
    #expect(
      ids.contains(
        TranscriptStreamingTextIdentity.mainResponseSegment(
          turnID: turnID,
          entryID: "answer",
          segmentIndex: 2
        )))
    #expect(
      !ids.contains(
        TranscriptStreamingTextIdentity.mainResponseSegment(
          turnID: turnID,
          entryID: "answer",
          segmentIndex: 1
        )))
  }

  @Test("Attachment-only response surfaces are settled on navigation")
  func settledAttachmentOnlyResponse() {
    let turnID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let attachment = Attachment(
      fileId: "file-1",
      name: "plot.png",
      mimeType: "image/png",
      sizeBytes: 42,
      kind: .image
    )
    let turn = AssistantTurn(
      attachments: [attachment],
      isGenerating: false
    )

    let ids = Set(
      TranscriptStreamingTextIdentity.settledStreamIDs(
        turn: turn,
        turnID: turnID
      )
    )

    #expect(
      ids.contains(
        TranscriptStreamingTextIdentity.main(
          turnID: turnID,
          entryID: "attachments"
        )))
  }
}

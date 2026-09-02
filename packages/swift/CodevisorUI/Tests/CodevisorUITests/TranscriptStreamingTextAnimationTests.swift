import ACPKit
import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

@Suite("Transcript streaming text identity")
struct TranscriptStreamingTextAnimationTests {
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

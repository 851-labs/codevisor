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
                "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE:subagent:agent-1:t0",
            ])
    }
}

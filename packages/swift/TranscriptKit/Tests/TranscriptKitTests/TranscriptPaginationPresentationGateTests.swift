import Testing
@testable import TranscriptKit

@Suite("Transcript pagination presentation gate")
struct TranscriptPaginationPresentationGateTests {
    @Test("Complete transcripts never start feedback")
    func completeTranscriptDoesNotStart() {
        var gate = TranscriptPaginationPresentationGate()

        #expect(gate.begin(hasOlderHistory: false) == nil)
        #expect(!gate.isPresented)
        #expect(gate.presentationTarget == nil)
    }

    @Test("Feedback spans the request and matching native commit")
    func waitsForNativeCommit() {
        var gate = TranscriptPaginationPresentationGate()
        let token = gate.begin(hasOlderHistory: true)

        #expect(token == 1)
        #expect(gate.isPresented)
        #expect(gate.presentationTarget == nil)

        gate.requestDidFinish(
            token: 1,
            insertedItemCount: 8,
            oldestRowKey: "message:older"
        )
        #expect(gate.isPresented)
        #expect(
            gate.presentationTarget
                == .init(
                    token: 1,
                    oldestRowKey: "message:older"
                ))

        let staleCommit = gate.didPresent(token: 2)
        #expect(!staleCommit)
        #expect(gate.isPresented)
        let matchingCommit = gate.didPresent(token: 1)
        #expect(matchingCommit)
        #expect(!gate.isPresented)
    }

    @Test("An empty page or failure ends feedback without a presentation wait")
    func emptyPageEndsFeedback() {
        var gate = TranscriptPaginationPresentationGate()
        let token = gate.begin(hasOlderHistory: true)!

        gate.requestDidFinish(
            token: token,
            insertedItemCount: 0,
            oldestRowKey: nil
        )

        #expect(!gate.isPresented)
        #expect(gate.presentationTarget == nil)
    }

    @Test("Cancellation and stale completions cannot affect a later request")
    func staleCompletionIsIgnored() {
        var gate = TranscriptPaginationPresentationGate()
        let first = gate.begin(hasOlderHistory: true)!
        gate.cancel(token: first)
        let second = gate.begin(hasOlderHistory: true)!

        gate.requestDidFinish(
            token: first,
            insertedItemCount: 4,
            oldestRowKey: "message:stale"
        )

        #expect(gate.activeToken == second)
        #expect(gate.presentationTarget == nil)
    }
}

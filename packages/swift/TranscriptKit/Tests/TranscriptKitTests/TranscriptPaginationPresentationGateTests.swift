import Foundation
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
        #expect(gate.requiredProjectionKey == nil)
        #expect(gate.presentationTarget == nil)

        let requiredKey = projectionKey(controllerRevision: 2, modelRevision: 4)
        gate.requestDidFinish(
            token: 1,
            insertedItemCount: 8,
            requiredProjectionKey: requiredKey
        )
        #expect(gate.isPresented)
        #expect(gate.requiredProjectionKey == requiredKey)
        #expect(gate.presentationTarget == nil)

        gate.projectionDidPublish(
            key: projectionKey(controllerRevision: 2, modelRevision: 3),
            revision: 9
        )
        #expect(gate.presentationTarget == nil)

        gate.projectionDidPublish(
            key: projectionKey(controllerRevision: 3, modelRevision: 5),
            revision: 10
        )
        #expect(
            gate.presentationTarget
                == .init(
                    token: 1,
                    projectionRevision: 10
                ))

        let staleCommit = gate.didPresent(token: 2)
        #expect(!staleCommit)
        #expect(gate.isPresented)
        let matchingCommit = gate.didPresent(token: 1)
        #expect(matchingCommit)
        #expect(!gate.isPresented)
        #expect(gate.requiredProjectionKey == nil)
    }

    @Test("An empty page or failure ends feedback without a presentation wait")
    func emptyPageEndsFeedback() {
        var gate = TranscriptPaginationPresentationGate()
        let token = gate.begin(hasOlderHistory: true)!

        gate.requestDidFinish(
            token: token,
            insertedItemCount: 0,
            requiredProjectionKey: nil
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
            requiredProjectionKey: projectionKey(
                controllerRevision: 1,
                modelRevision: 1
            )
        )

        #expect(gate.activeToken == second)
        #expect(gate.requiredProjectionKey == nil)
        #expect(gate.presentationTarget == nil)
    }

    private func projectionKey(
        controllerRevision: UInt64,
        modelRevision: UInt64
    ) -> TranscriptProjectionKey {
        TranscriptProjectionKey(
            sessionID: UUID(uuidString: "4D178F54-6274-4719-BBD2-447CF7316308")!,
            controllerRevision: controllerRevision,
            modelRevision: modelRevision
        )
    }
}

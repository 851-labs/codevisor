import Testing
@testable import CodevisorCore

struct TranscriptMeasurementCommitGateTests {
    @Test func blocksGeometryForTheWholeDragAndMomentumSequence() {
        var gate = TranscriptMeasurementCommitGate()
        #expect(gate.allowsGeometryCommit)

        gate.draggingDidBegin()
        #expect(gate.phase == .dragging)
        #expect(!gate.allowsGeometryCommit)

        gate.draggingDidEnd(willDecelerate: true)
        #expect(gate.phase == .decelerating)
        #expect(!gate.allowsGeometryCommit)

        gate.interactionDidEnd()
        #expect(gate.phase == .idle)
        #expect(gate.allowsGeometryCommit)
    }

    @Test func nonDeceleratingDragReleasesGeometryImmediately() {
        var gate = TranscriptMeasurementCommitGate()
        gate.draggingDidBegin()
        gate.draggingDidEnd(willDecelerate: false)

        #expect(gate.phase == .idle)
        #expect(gate.allowsGeometryCommit)
    }
}

import Testing
@testable import TranscriptKit

struct TranscriptMeasurementCommitGateTests {
  @Test func blocksOnlySystemOwnedDeceleration() {
    var gate = TranscriptMeasurementCommitGate()

    #expect(gate.phase == .idle)
    #expect(gate.allowsGeometryCommit)

    gate.draggingDidBegin()
    #expect(gate.phase == .dragging)
    #expect(gate.allowsGeometryCommit)

    gate.draggingDidEnd(willDecelerate: true)
    #expect(gate.phase == .decelerating)
    #expect(!gate.allowsGeometryCommit)

    gate.interactionDidEnd()
    #expect(gate.phase == .idle)
    #expect(gate.allowsGeometryCommit)
  }

  @Test func dragWithoutMomentumReturnsDirectlyToIdle() {
    var gate = TranscriptMeasurementCommitGate()

    gate.draggingDidBegin()
    gate.draggingDidEnd(willDecelerate: false)

    #expect(gate.phase == .idle)
    #expect(gate.allowsGeometryCommit)
  }

  @Test func newDragInterruptsDecelerationAndAllowsCommits() {
    var gate = TranscriptMeasurementCommitGate()
    gate.draggingDidBegin()
    gate.draggingDidEnd(willDecelerate: true)

    gate.draggingDidBegin()

    #expect(gate.phase == .dragging)
    #expect(gate.allowsGeometryCommit)
  }
}

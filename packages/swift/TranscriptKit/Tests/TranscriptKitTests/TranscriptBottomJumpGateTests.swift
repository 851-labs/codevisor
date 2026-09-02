import Testing
@testable import TranscriptKit

@Suite("Transcript bottom-jump gate")
struct TranscriptBottomJumpGateTests {
  @Test("A jump remains active until every destination row is resolved")
  func waitsForDestinationGeometry() {
    var gate = TranscriptBottomJumpGate()
    gate.begin()

    let partialResolution = gate.resolve(
      requiredKeys: ["message:a", "message:b"],
      resolvedKeys: ["message:a"],
      hasPendingMeasurements: false
    )
    #expect(!partialResolution)
    #expect(gate.isActive)

    let fullResolution = gate.resolve(
      requiredKeys: ["message:a", "message:b"],
      resolvedKeys: ["message:a", "message:b"],
      hasPendingMeasurements: false
    )
    #expect(fullResolution)
    #expect(!gate.isActive)
  }

  @Test("Pending measurements prevent an early release")
  func waitsForPendingMeasurements() {
    var gate = TranscriptBottomJumpGate()
    gate.begin()

    let resolution = gate.resolve(
      requiredKeys: ["message:a"],
      resolvedKeys: ["message:a"],
      hasPendingMeasurements: true
    )
    #expect(!resolution)
    #expect(gate.isActive)
  }

  @Test("Direct user movement cancels the jump intent")
  func cancellationWins() {
    var gate = TranscriptBottomJumpGate()
    gate.begin()
    gate.cancel()

    let resolution = gate.resolve(
      requiredKeys: ["message:a"],
      resolvedKeys: ["message:a"],
      hasPendingMeasurements: false
    )
    #expect(!resolution)
    #expect(!gate.isActive)
  }
}

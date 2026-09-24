import Testing
@testable import TranscriptKit

struct TranscriptInitialPresentationGateTests {
  @Test func hydrationCannotRevealAnEmptyPlaceholder() {
    var gate = TranscriptInitialPresentationGate()

    let revealed = gate.resolve(
      isHydrating: true,
      requiredKeys: [],
      resolvedKeys: [],
    )
    #expect(!revealed)
    #expect(!gate.isReady)
  }

  @Test func uncachedWindowWaitsForEveryRequiredRow() {
    var gate = TranscriptInitialPresentationGate()

    let partialReveal = gate.resolve(
      isHydrating: false,
      requiredKeys: ["a", "b", "c"],
      resolvedKeys: ["a", "c"],
    )
    #expect(!partialReveal)
    #expect(!gate.isReady)

    let completeReveal = gate.resolve(
      isHydrating: false,
      requiredKeys: ["a", "b", "c"],
      resolvedKeys: ["a", "b", "c"],
    )
    #expect(completeReveal)
    #expect(gate.isReady)
  }

  @Test func changingInitialWindowMustAlsoResolveNewRows() {
    var gate = TranscriptInitialPresentationGate()

    let firstWindowReveal = gate.resolve(
      isHydrating: false,
      requiredKeys: ["a", "b"],
      resolvedKeys: ["a"],
    )
    #expect(!firstWindowReveal)
    let changedWindowReveal = gate.resolve(
      isHydrating: false,
      requiredKeys: ["b", "c"],
      resolvedKeys: ["a", "b"],
    )
    #expect(!changedWindowReveal)
    let finalReveal = gate.resolve(
      isHydrating: false,
      requiredKeys: ["b", "c"],
      resolvedKeys: ["a", "b", "c"],
    )
    #expect(finalReveal)
  }

  @Test func waitsForPendingMeasurementCommit() {
    var gate = TranscriptInitialPresentationGate()
    let keys: Set<String> = ["row"]

    let pendingReveal = gate.resolve(
      isHydrating: false,
      requiredKeys: keys,
      resolvedKeys: keys,
      hasPendingMeasurements: true
    )
    #expect(!pendingReveal)
    #expect(!gate.isReady)
    let committedReveal = gate.resolve(
      isHydrating: false,
      requiredKeys: keys,
      resolvedKeys: keys,
      hasPendingMeasurements: false
    )
    #expect(committedReveal)
    #expect(gate.isReady)
  }

  @Test func provisionalActiveRowCannotRevealBeforeBlockProjectionPublishes() {
    var gate = TranscriptInitialPresentationGate()
    let keys: Set<String> = ["active-fallback"]

    let provisionalReveal = gate.resolve(
      isHydrating: false,
      isActiveProjectionPending: true,
      requiredKeys: keys,
      resolvedKeys: keys
    )
    #expect(!provisionalReveal)
    #expect(!gate.isReady)

    let finalTopologyReveal = gate.resolve(
      isHydrating: false,
      isActiveProjectionPending: false,
      requiredKeys: ["markdown-0", "markdown-1"],
      resolvedKeys: ["markdown-0", "markdown-1"]
    )
    #expect(finalTopologyReveal)
    #expect(gate.isReady)
  }

  @Test func cachedWindowRevealsImmediatelyAndNeverHidesAgain() {
    var gate = TranscriptInitialPresentationGate()

    let cachedReveal = gate.resolve(
      isHydrating: false,
      requiredKeys: ["cached"],
      resolvedKeys: ["cached"],
    )
    #expect(cachedReveal)
    let secondReveal = gate.resolve(
      isHydrating: true,
      requiredKeys: ["different"],
      resolvedKeys: [],
    )
    #expect(!secondReveal)
    #expect(gate.isReady)
  }

  @Test func firstSendFlightOpensAGateItsHeldRowsKeepClosed() {
    var gate = TranscriptInitialPresentationGate()
    // A new chat's flight holds back the active projection and a row beneath
    // its target, so normal readiness cannot resolve until the reply lands.
    let normalReveal = gate.resolve(
      isHydrating: false,
      isActiveProjectionPending: true,
      requiredKeys: ["message", "setup", "spacer"],
      resolvedKeys: ["message", "spacer"],
    )
    #expect(!normalReveal)

    let flightReveal = gate.openForSendPresentation(isHydrating: false)
    #expect(flightReveal)
    #expect(gate.isReady)
    let repeatedReveal = gate.openForSendPresentation(isHydrating: false)
    #expect(!repeatedReveal)
  }

  @Test func firstSendFlightNeverRevealsHydratingHistory() {
    var gate = TranscriptInitialPresentationGate()

    let revealed = gate.openForSendPresentation(isHydrating: true)
    #expect(!revealed)
    #expect(!gate.isReady)
  }
}

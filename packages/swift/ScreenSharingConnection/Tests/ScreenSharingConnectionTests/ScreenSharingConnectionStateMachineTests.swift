import Testing

@testable import ScreenSharingConnection

@Suite("Screen share connection: which failures stay while hidden")
struct ScreenSharingConnectionStateMachineTests {
  private func failed(with end: ScreenSharingAttemptEnd) -> ScreenSharingConnectionStateMachine {
    var machine = ScreenSharingConnectionStateMachine()
    _ = machine.handle(.surfacesChanged(attached: true, visible: true))
    _ = machine.handle(.attemptEnded(end))
    return machine
  }

  nonisolated static let hostDecided: [ScreenSharingAttemptEnd] = [
    .refused(.stoppedOnHost), .refused(.displayAsleep), .refused(.sessionSwitched),
    .refused(.inUse(by: "Alexandru's iPhone")), .refused(.inUseOldHost),
    .refused(.takenOver(by: "Alexandru's iPhone")), .endedByHost(message: "Screen sharing was stopped."),
  ]

  @Test("Hiding the surfaces of a failure the host decided starts no countdown, and showing them asks for nothing")
  func keepsHostDecidedFailures() {
    for end in Self.hostDecided {
      var machine = failed(with: end)
      let failure = machine.state

      let hidden = machine.handle(.surfacesChanged(attached: true, visible: false))
      #expect(hidden == nil && machine.unseen == nil && machine.state == failure)
      #expect(machine.handle(.systemWoke) == nil && machine.handle(.machineCameOnline) == nil)
      #expect(machine.handle(.surfacesChanged(attached: true, visible: true)) == nil && machine.state == failure)
    }
  }

  @Test("A failure the host decided turns off once its last surface has been detached for the short countdown")
  func turnsOffHostDecidedFailuresWithoutSurfaces() {
    for end in Self.hostDecided {
      var machine = failed(with: end)

      _ = machine.handle(.surfacesChanged(attached: false, visible: false))
      #expect(machine.unseen == .briefly)
      #expect(machine.handle(.unseenBrieflyElapsed) == .stop && machine.state == .off)
    }
  }

  nonisolated static let ordinary: [ScreenSharingAttemptEnd] = [
    .dropped(.cantReach), .dropped(.noVideo), .dropped(.networkBlocked), .refused(.permissionMissing),
    .refused(.updateNeeded), .refused(.noDisplay), .refused(.noWorkspace), .refused(.unsupportedOnThisDevice),
    .hostFailed(message: "The host Mac couldn't start capturing its screen."),
  ]

  @Test("Any other failure turns off after the short countdown with nothing on screen, even with a surface attached")
  func turnsOffOrdinaryFailuresNobodyLooksAt() {
    for end in Self.ordinary {
      var machine = failed(with: end)

      _ = machine.handle(.surfacesChanged(attached: true, visible: false))
      #expect(machine.unseen == .briefly)
      #expect(machine.handle(.unseenBrieflyElapsed) == .stop && machine.state == .off)
    }
  }
}

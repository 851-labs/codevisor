import Testing
@testable import CodevisorScreenSharing

struct ScreenSharingDecoderRecoveryCheckTests {
  @Test func encoderFaultIsArmedOnlyAtTheDecoderResetEdge() {
    let decoder = ScreenSharingDecoderRecoveryCheck()
    let outputDrop = ScreenSharingEncoderDropCheck()
    decoder.arm(afterFrames: 2) {
      // Reentry also verifies the notification runs outside the state lock.
      #expect(decoder.inspect(keyFrame: false, nowNs: 2) == .rejectDelta)
      outputDrop.arm()
    }
    #expect(!outputDrop.consume())
    #expect(decoder.inspect(keyFrame: true, nowNs: 0) == .accept)
    #expect(!outputDrop.consume())
    #expect(decoder.inspect(keyFrame: false, nowNs: 1) == .reset)
    #expect(outputDrop.consume())
    #expect(!outputDrop.consume())
    #expect(decoder.inspect(keyFrame: true, nowNs: 3) == .recovered(milliseconds: 0.000002))
    #expect(!outputDrop.consume())
  }

  @Test func unarmedDecoderDoesNotDiscardFrames() {
    let check = ScreenSharingDecoderRecoveryCheck()
    #expect(check.inspect(keyFrame: false, nowNs: 0) == .accept)
    #expect(check.inspect(keyFrame: true, nowNs: 1) == .accept)
  }

  @Test func lossRequiresANewKeyframeAndOccursOnlyOnce() {
    let check = ScreenSharingDecoderRecoveryCheck()
    check.arm(afterFrames: 3)
    #expect(check.inspect(keyFrame: true, nowNs: 0) == .accept)
    #expect(check.inspect(keyFrame: false, nowNs: 10_000_000) == .accept)
    #expect(check.inspect(keyFrame: false, nowNs: 20_000_000) == .reset)
    #expect(check.inspect(keyFrame: false, nowNs: 30_000_000) == .rejectDelta)
    #expect(check.inspect(keyFrame: false, nowNs: 40_000_000) == .rejectDelta)
    #expect(check.inspect(keyFrame: true, nowNs: 70_000_000) == .recovered(milliseconds: 50))
    #expect(check.inspect(keyFrame: false, nowNs: 80_000_000) == .accept)
    #expect(check.inspect(keyFrame: true, nowNs: 90_000_000) == .accept)
  }

  @Test func aKeyframeChosenForTheFaultCannotAlsoSatisfyRecovery() {
    let check = ScreenSharingDecoderRecoveryCheck()
    check.arm(afterFrames: 1)
    #expect(check.inspect(keyFrame: true, nowNs: 0) == .reset)
    #expect(check.inspect(keyFrame: false, nowNs: 1) == .rejectDelta)
    #expect(check.inspect(keyFrame: true, nowNs: 2_000_000) == .recovered(milliseconds: 2))
  }
}

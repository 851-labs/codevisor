import CodevisorTestSupport
import Testing
@testable import ScreenSharing

struct ScreenSharingDecoderRecoveryCheckTests {
  private func elapsedNs(_ clock: TestClock, since origin: ContinuousClock.Instant) -> Int64 {
    let elapsed = origin.duration(to: clock.now)
    return elapsed.components.seconds * 1_000_000_000 + elapsed.components.attoseconds / 1_000_000_000
  }

  @Test func encoderFaultIsArmedOnlyAtTheDecoderResetEdge() {
    let decoder = ScreenSharingDecoderRecoveryCheck()
    let outputDrop = ScreenSharingEncoderDropCheck()
    decoder.arm(afterFrames: 2) {
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

  @Test func theOutageIsMeasuredFromTheResetFrameToTheKeyframeThatEndsIt() {
    let clock = TestClock()
    let origin = clock.now
    let check = ScreenSharingDecoderRecoveryCheck()
    check.arm(afterFrames: 2)
    #expect(check.inspect(keyFrame: true, nowNs: elapsedNs(clock, since: origin)) == .accept)
    clock.advance(by: .milliseconds(33))
    #expect(check.inspect(keyFrame: false, nowNs: elapsedNs(clock, since: origin)) == .reset)
    for _ in 0..<3 {
      clock.advance(by: .milliseconds(16))
      #expect(check.inspect(keyFrame: false, nowNs: elapsedNs(clock, since: origin)) == .rejectDelta)
    }
    clock.advance(by: .milliseconds(2))
    #expect(check.inspect(keyFrame: true, nowNs: elapsedNs(clock, since: origin)) == .recovered(milliseconds: 50))
  }

  @Test func reArmingDuringAnOutageReplacesTheFaultAndItsCountdown() {
    let clock = TestClock()
    let origin = clock.now
    let check = ScreenSharingDecoderRecoveryCheck()
    let first = TestSignal()
    let second = TestSignal()
    check.arm(afterFrames: 1, onReset: { first.signal() })
    #expect(check.inspect(keyFrame: false, nowNs: elapsedNs(clock, since: origin)) == .reset)
    #expect(first.value == 1)
    clock.advance(by: .milliseconds(10))
    check.arm(afterFrames: 2, onReset: { second.signal() })
    #expect(check.inspect(keyFrame: false, nowNs: elapsedNs(clock, since: origin)) == .accept)
    clock.advance(by: .milliseconds(10))
    #expect(check.inspect(keyFrame: false, nowNs: elapsedNs(clock, since: origin)) == .reset)
    #expect(first.value == 1 && second.value == 1)
    clock.advance(by: .milliseconds(5))
    #expect(check.inspect(keyFrame: true, nowNs: elapsedNs(clock, since: origin)) == .recovered(milliseconds: 5))
  }

  @Test func aResetNotificationBelongsToItsOwnFaultOnly() {
    let check = ScreenSharingDecoderRecoveryCheck()
    let notified = TestSignal()
    check.arm(afterFrames: 1, onReset: { notified.signal() })
    #expect(check.inspect(keyFrame: false, nowNs: 0) == .reset)
    #expect(notified.value == 1)
    #expect(check.inspect(keyFrame: true, nowNs: 1_000_000) == .recovered(milliseconds: 1))
    check.arm(afterFrames: 1)
    #expect(check.inspect(keyFrame: false, nowNs: 2_000_000) == .reset)
    #expect(notified.value == 1)
  }

  @Test func aBackwardsTimestampReportsNoOutageRatherThanANegativeOne() {
    let check = ScreenSharingDecoderRecoveryCheck()
    check.arm(afterFrames: 1)
    #expect(check.inspect(keyFrame: false, nowNs: 5_000_000) == .reset)
    #expect(check.inspect(keyFrame: true, nowNs: 1_000_000) == .recovered(milliseconds: 0))
  }
}

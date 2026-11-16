import Testing
@testable import CodevisorUI

struct BotMascotMotionPacerTests {
  private static let start = ContinuousClock.Instant.now
  private static let hold = BotMascotMotionPacer.minimumHold
  private static let settle = BotMascotMotionPacer.settle

  @Test("The first motion plays right away")
  func firstMotionPlaysAtOnce() {
    #expect(BotMascotMotionPacer().wait(before: .working, at: Self.start) == .zero)
  }

  @Test("The first animation gives way once the next one settles, without the minimum hold")
  func firstAnimationIsNotHeld() {
    var pacer = BotMascotMotionPacer()
    pacer.shown(.sleeping, at: Self.start)

    #expect(pacer.wait(before: .working, at: Self.start) == Self.settle)
  }

  @Test("A later animation waits until the shown one has played for the minimum hold")
  func laterAnimationWaitsOutTheHold() {
    let pacer = Self.pacerPastItsFirstAnimation()

    #expect(pacer.wait(before: .calling, at: Self.start + .seconds(1)) == Self.hold - .seconds(1))
  }

  @Test("After the hold, a new animation still has to settle before it plays")
  func newAnimationSettlesAfterTheHold() {
    let pacer = Self.pacerPastItsFirstAnimation()

    #expect(pacer.wait(before: .calling, at: Self.start + .seconds(60)) == Self.settle)
  }

  private static func pacerPastItsFirstAnimation() -> BotMascotMotionPacer {
    var pacer = BotMascotMotionPacer()
    pacer.shown(.sleeping, at: start - .seconds(60))
    pacer.shown(.working, at: start)
    return pacer
  }

  @Test("Motions that share an animation switch at once and don't restart the hold")
  func sameAnimationSwitchesAtOnce() {
    var pacer = BotMascotMotionPacer()
    pacer.shown(.idle, at: Self.start)
    pacer.shown(.watching, at: Self.start + .seconds(1))

    #expect(pacer.wait(before: .idle, at: Self.start + .seconds(1)) == .zero)
    #expect(pacer.wait(before: .working, at: Self.start + Self.hold) == Self.settle)
  }
}

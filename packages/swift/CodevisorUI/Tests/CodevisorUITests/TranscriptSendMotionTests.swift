import CoreGraphics
import QuartzCore
import Testing
@testable import CodevisorUI

@Suite("Transcript send motion")
struct TranscriptSendMotionTests {
  @Test("The bubble overshoots its slot by a few percent of its travel, then settles")
  func bubbleOvershootsAndSettles() {
    let spring = TranscriptSendMotion.bubble
    let samples = stride(from: 0.0, through: 1.5, by: 1.0 / 240).map(spring.displacementFraction(at:))
    let overshoot = -(samples.min() ?? 0)
    #expect(overshoot > 0.025 && overshoot < 0.05)
    let peak = samples.firstIndex(of: -overshoot) ?? 0
    #expect(samples[peak...].allSatisfy { $0 < 0.005 })
    #expect(spring.settlingDuration() > 0.45 && spring.settlingDuration() < 0.7)
    #expect(abs(spring.displacementFraction(at: spring.settlingDuration())) <= 0.002)
  }

  @Test("History makes room without overshooting, ahead of the bubble")
  func contentNeverOvershoots() {
    let spring = TranscriptSendMotion.content
    let samples = stride(from: 0.0, through: 1.0, by: 1.0 / 240).map(spring.displacementFraction(at:))
    #expect(samples.allSatisfy { $0 >= 0 })
    #expect(spring.settlingDuration() < TranscriptSendMotion.bubble.settlingDuration())
    #expect(spring.displacementFraction(at: 0.15) < TranscriptSendMotion.bubble.displacementFraction(at: 0.15))
  }

  @Test("The history push rides the bubble's spring and holds its end")
  func pushRidesTheBubbleSpring() {
    let push = TranscriptSendLayerAnimations.push(200, from: -30, beginTime: 12)
    #expect(push.keyPath == "transform.translation.y")
    #expect(push.isAdditive)
    #expect(push.fromValue as? CGFloat == -30)
    #expect(push.toValue as? CGFloat == -230)
    #expect(push.beginTime == 12)
    #expect(!push.isRemovedOnCompletion)
    #expect(abs(push.stiffness - TranscriptSendMotion.bubble.stiffness) < 0.001)
    #expect(abs(push.damping - TranscriptSendMotion.bubble.damping) < 0.001)
  }

  @Test("A shift runs for its own spring's settling time")
  func shiftRunsForItsSpring() {
    let bubble = TranscriptSendShift(offset: 100, beginTime: 10, serial: 1, spring: TranscriptSendMotion.bubble)
    let content = TranscriptSendShift(offset: 100, beginTime: 10, serial: 2)
    let between = 10 + TranscriptSendMotion.content.settlingDuration() + 0.01
    #expect(bubble.isRunning(at: between))
    #expect(!content.isRunning(at: between))
  }

  @Test("Core Animation receives the same physical spring")
  func coreAnimationParametersMatchTheModel() {
    let spring = TranscriptSendMotion.bubble
    let animation = TranscriptSendLayerAnimations.translation(CGSize(width: 0, height: 300), spring: spring)
    #expect(animation.mass == 1)
    #expect(abs(animation.stiffness - spring.stiffness) < 0.001)
    #expect(abs(animation.damping - spring.damping) < 0.001)
    #expect(animation.isAdditive)
    #expect(animation.duration == spring.settlingDuration())
  }

  @Test("Rows mounted after a send share one reveal, so a replacement row never restarts the fade")
  func followersShareOneReveal() {
    let sent: CFTimeInterval = 50
    let revealAt = sent + TranscriptSendMotion.followerRevealDelay
    let mounts = [sent, revealAt + 0.05, revealAt + TranscriptSendMotion.followerFadeDuration - 0.01]

    let reveals = mounts.map { TranscriptSendLayerAnimations.followerReveal(sendStartedAt: sent, now: $0) }

    #expect(reveals.allSatisfy { $0?.beginTime == revealAt })
    #expect(
      TranscriptSendLayerAnimations.followerReveal(
        sendStartedAt: sent, now: revealAt + TranscriptSendMotion.followerFadeDuration) == nil)
  }
}

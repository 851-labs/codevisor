import Foundation
import Testing
@testable import TranscriptSurface

@Suite("Transcript bottom slack")
struct TranscriptBottomSlackTests {
  @Test("A shrink becomes slack and later growth consumes it before content moves")
  func absorbsShrinkThenGrowthConsumesIt() {
    var slack = TranscriptBottomSlack()
    slack.absorb(rowsHeightChange: -120, at: 10)
    #expect(slack.height == 120)

    slack.absorb(rowsHeightChange: 50, at: 10.01)
    #expect(slack.height == 70)

    slack.absorb(rowsHeightChange: 200, at: 10.02)
    #expect(slack.height == 0)
  }

  @Test("Slack holds briefly, then eases out by half every half-life")
  func holdsThenDecays() {
    var slack = TranscriptBottomSlack()
    slack.absorb(rowsHeightChange: -100, at: 0)

    let decayedDuringHold = slack.decay(at: 0.1)
    #expect(!decayedDuringHold)
    #expect(slack.height == 100)

    let startedEasing = slack.decay(at: 0.12)
    #expect(startedEasing)
    #expect(slack.height == 100)
    let eased = slack.decay(at: 0.12 + 1.0 / 60)
    #expect(eased)
    #expect(abs(slack.height - 100 * pow(0.5, (1.0 / 60) / 0.07)) < 0.001)
  }

  @Test("A late frame moves slack by at most one short step")
  func stalledFrameCannotJump() {
    var slack = TranscriptBottomSlack()
    slack.absorb(rowsHeightChange: -300, at: 0)
    _ = slack.decay(at: 0.12)

    _ = slack.decay(at: 1.12)

    #expect(abs(slack.height - 300 * pow(0.5, (1.0 / 30) / 0.07)) < 0.001)
  }

  @Test("Reset drops all slack")
  func resetClears() {
    var slack = TranscriptBottomSlack()
    slack.absorb(rowsHeightChange: -40, at: 0)
    slack.reset()

    #expect(!slack.isActive)
  }
}

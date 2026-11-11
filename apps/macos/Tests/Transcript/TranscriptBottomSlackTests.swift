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

  @Test("Slack stays while text keeps arriving and eases out once it goes quiet")
  func holdsWhileStreamingThenDecays() {
    var slack = TranscriptBottomSlack()
    slack.absorb(rowsHeightChange: -100, at: 0)
    slack.absorb(rowsHeightChange: 21, at: 0.5)

    let decayedWhileStreaming = slack.decay(at: 0.9)
    #expect(!decayedWhileStreaming)
    #expect(slack.height == 79)

    let startedEasing = slack.decay(at: 1.1)
    #expect(startedEasing)
    #expect(slack.height == 79)
    let eased = slack.decay(at: 1.1 + 1.0 / 60)
    #expect(eased)
    #expect(abs(slack.height - 79 * pow(0.5, (1.0 / 60) / 0.07)) < 0.001)
  }

  @Test("A late frame moves slack by at most one short step")
  func stalledFrameCannotJump() {
    var slack = TranscriptBottomSlack()
    slack.absorb(rowsHeightChange: -300, at: 0)
    _ = slack.decay(at: 0.6)

    _ = slack.decay(at: 1.6)

    #expect(abs(slack.height - 300 * pow(0.5, (1.0 / 30) / 0.07)) < 0.001)
  }

  @Test("While text streams, slack above the held limit eases out right away")
  func excessSlackEasesWhileStreaming() {
    var slack = TranscriptBottomSlack()
    slack.absorb(rowsHeightChange: -300, at: 0)

    let eased = slack.decay(at: 1.0 / 60)

    #expect(eased)
    #expect(abs(slack.height - (120 + 180 * pow(0.5, (1.0 / 60) / 0.07))) < 0.001)
  }

  @Test("Reset drops all slack")
  func resetClears() {
    var slack = TranscriptBottomSlack()
    slack.absorb(rowsHeightChange: -40, at: 0)
    slack.reset()

    #expect(!slack.isActive)
  }
}

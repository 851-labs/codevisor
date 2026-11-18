import ScreenSharingConnection
import Testing

@Suite("Screen share connection: failure wording")
struct ScreenSharingFailureReasonTests {
  nonisolated static let sentences: [(ScreenSharingFailureReason, String)] = [
    (.cantReach, "Can't reach croissant. Check that it's awake and online."),
    (.takenOver(by: "Alexandru's iPhone"), "Now viewing on Alexandru's iPhone."),
    (.inUse(by: "Alexandru's iPhone"), "In use on Alexandru's iPhone."),
    (.takenOver(by: nil), "croissant is in use on another device."),
    (.inUse(by: nil), "croissant is in use on another device."),
    (.stoppedOnHost, "Sharing was stopped on croissant."),
    (.displayAsleep, "croissant's display is asleep."),
    (.sessionSwitched, "Another user is logged in on croissant."),
    (
      .permissionMissing,
      "croissant isn't letting Codevisor record its screen. Check Screen Recording in its System Settings."
    ),
    (.updateNeeded, "Update Codevisor on croissant."),
    (.networkBlocked, "Couldn't open a video connection to croissant."),
    (.noVideo, "Connected, but croissant sent no picture."),
    (.keptDropping, "The connection to croissant keeps dropping."),
    (.noDisplay, "croissant has no display to share."),
    (
      .nothingToView(message: "The agent is not controlling an app right now."),
      "The agent is not controlling an app right now."
    ),
    (.nothingToView(message: nil), "Nothing to show on croissant yet."),
    (.unsupportedOnThisDevice, "croissant's desktop can only be viewed from a Mac."),
    (.unclassified(message: "The encoder stopped."), "The encoder stopped."),
    (.unclassified(message: nil), "croissant can't share its screen right now."),
  ]

  @Test("Every failure reason has one sentence that names the machine, the holder or the machine's own message")
  func saysWhatWentWrong() {
    for (reason, sentence) in Self.sentences {
      #expect(reason.sentence(on: "croissant") == sentence)
    }
  }
}

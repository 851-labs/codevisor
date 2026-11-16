import ScreenSharingConnection
import Testing

@Suite("Screen share connection: the button each failure offers")
struct ScreenSharingFailureActionTests {
  nonisolated static let actions: [(ScreenSharingFailureReason, ScreenSharingFailureAction?)] = [
    (.cantReach, .retry),
    (.takenOver(by: "Alexandru's iPhone"), .viewHere),
    (.inUse(by: "Alexandru's iPhone"), .viewHere),
    (.takenOver(by: nil), .viewHere),
    (.inUse(by: nil), .viewHere),
    (.stoppedOnHost, .connect),
    (.displayAsleep, .retry),
    (.sessionSwitched, .retry),
    (.permissionMissing, .retry),
    (.updateNeeded, nil),
    (.networkBlocked, .retry),
    (.noVideo, .retry),
    (.keptDropping, .retry),
    (.noDisplay, .retry),
    (.nothingToView(message: "The agent is not controlling an app right now."), .retry),
    (.nothingToView(message: nil), .retry),
    (.unsupportedOnThisDevice, nil),
    (.unclassified(message: "The encoder stopped."), .retry),
    (.unclassified(message: nil), .retry),
  ]

  @Test("A device that lost the desktop to another offers View here, a stop on the host offers Connect, a fault Retry")
  func offersOneButtonPerReason() {
    for (reason, action) in Self.actions {
      #expect(ScreenSharingFailureAction(for: reason) == action, "\(reason)")
    }
  }

  @Test("Every reason the sentences cover has a button decided")
  func coversEveryReason() {
    let withButtons = Self.actions.map(\.0)
    for (reason, _) in ScreenSharingFailureReasonTests.sentences {
      #expect(withButtons.contains(reason), "\(reason)")
    }
  }
}

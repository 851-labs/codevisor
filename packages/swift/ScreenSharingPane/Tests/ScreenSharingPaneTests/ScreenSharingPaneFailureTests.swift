import ScreenSharingConnection
import Testing

@testable import ScreenSharingPane

struct ScreenSharingPaneFailureTests {
  @Test(
    "View here whenever another device holds the desktop, no button where retrying can't help, Try Again otherwise",
    arguments: [
      (ScreenSharingFailureReason.takenOver(by: "Alexandru's MacBook Pro"), ScreenSharingPaneFailure.Action.viewHere),
      (.takenOver(by: nil), .viewHere),
      (.inUse(by: "Alexandru's MacBook Pro"), .viewHere),
      (.inUse(by: nil), .viewHere),
      (.inUseOldHost, .tryAgain),
      (.unsupportedOnThisDevice, nil),
      (.stoppedOnHost, .tryAgain),
      (.cantReach, .tryAgain),
      (.unclassified(message: nil), .tryAgain),
    ] as [(ScreenSharingFailureReason, ScreenSharingPaneFailure.Action?)])
  func button(for reason: ScreenSharingFailureReason, is action: ScreenSharingPaneFailure.Action?) {
    #expect(ScreenSharingPaneFailure(reason: reason, machineName: "croissant").action == action)
  }
}

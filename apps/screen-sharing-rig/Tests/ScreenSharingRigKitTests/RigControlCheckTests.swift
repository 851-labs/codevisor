import ScreenSharing
import Testing

@testable import ScreenSharingRigKit

struct RigControlCheckTests {
  @Test func planIsOneMoveThenContiguousDownUpPairs() {
    let plan = RigControlCheckPlan.events(clicks: 2, x: 0.25, y: 0.75)
    #expect(plan.map(\.sequence) == [1, 2, 3, 4, 5])
    let pointer = ScreenSharingPointer(x: 0.25, y: 0.75)
    #expect(plan[0].event == .move(pointer, modifiers: 0))
    #expect(plan[1].event == .button(pointer, button: 0, down: true, clicks: 1, modifiers: 0))
    #expect(plan[2].event == .button(pointer, button: 0, down: false, clicks: 1, modifiers: 0))
    #expect(plan[4].event == .button(pointer, button: 0, down: false, clicks: 1, modifiers: 0))
    #expect(plan.allSatisfy { $0.event.isValid })
    #expect(RigControlCheckPlan.events(clicks: 0, x: 0.5, y: 0.5).count == 1)
    let withKeys = RigControlCheckPlan.events(clicks: 1, keys: 2, x: 0.5, y: 0.5)
    let space = RigControlCheckPlan.spaceKeyCode
    #expect(withKeys.map(\.sequence) == [1, 2, 3, 4, 5, 6, 7])
    #expect(withKeys[3].event == .key(code: space, down: true, repeatKey: false, modifiers: 0))
    #expect(withKeys[6].event == .key(code: space, down: false, repeatKey: false, modifiers: 0))
    #expect(RigControlCheckRequest(clicks: 3, keys: 2).expectedResponses == 5)
  }

  @Test func deliveredMeansTheCounterAdvancedByExactlyTheClicks() {
    let exact = RigControlCheckResponse(
      granted: true, deniedReason: nil, clicksSent: 3, responsesBefore: 10, responsesAfter: 13, revokedReason: nil)
    #expect(exact.delivered)
    let keys = RigControlCheckResponse(
      granted: true, deniedReason: nil, clicksSent: 3, keysSent: 2, responsesBefore: 10, responsesAfter: 15,
      revokedReason: nil)
    #expect(keys.delivered)
    let short = RigControlCheckResponse(
      granted: true, deniedReason: nil, clicksSent: 3, responsesBefore: 10, responsesAfter: 12, revokedReason: nil)
    #expect(!short.delivered)
    let unknown = RigControlCheckResponse(
      granted: false, deniedReason: "Accessibility", clicksSent: 0, responsesBefore: nil, responsesAfter: nil,
      revokedReason: nil)
    #expect(!unknown.delivered)
  }
}

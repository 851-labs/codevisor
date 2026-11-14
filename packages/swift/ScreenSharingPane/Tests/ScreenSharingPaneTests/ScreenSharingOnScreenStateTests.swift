import Testing

@testable import ScreenSharingPane

struct ScreenSharingOnScreenStateTests {
  @Test("The Desktop counts as on screen only in a window, with a size, in an active scene, and says so once")
  func needsAllThree() {
    var state = ScreenSharingOnScreenState()

    #expect(state.change { $0.isInWindow = true } == nil)
    #expect(state.change { $0.hasSize = true } == nil)
    #expect(state.change { $0.sceneIsActive = true } == true)
    #expect(state.change { $0.hasSize = true } == nil)
  }

  @Test(
    "Leaving the window, losing its size, or the scene going inactive each take it off screen",
    arguments: [
      \ScreenSharingOnScreenState.isInWindow, \ScreenSharingOnScreenState.hasSize,
      \ScreenSharingOnScreenState.sceneIsActive,
    ])
  func anyOneTakesItOff(_ condition: WritableKeyPath<ScreenSharingOnScreenState, Bool> & Sendable) {
    var state = ScreenSharingOnScreenState(isInWindow: true, sceneIsActive: true, hasSize: true)

    #expect(state.change { $0[keyPath: condition] = false } == false)
    #expect(state.change { $0[keyPath: condition] = true } == true)
  }
}

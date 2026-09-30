import Testing
@testable import CodevisorCore

@MainActor
@Suite("Transcript presentation clock")
struct TranscriptPresentationClockTests {
  @Test("The fastest visible display clock exclusively drives presentation")
  func fastestDisplayClockWins() {
    var presentations = 0
    let clock = TranscriptPresentationClock(
      present: { presentations += 1 }, preferPending: {}, reschedulePending: {}, onAppear: {}, onDisappear: {}
    )
    var sixtyHertzRequests = 0
    var oneTwentyHertzRequests = 0
    let sixty = clock.registerDriver(maximumFramesPerSecond: 60) {
      sixtyHertzRequests += 1
    }
    let oneTwenty = clock.registerDriver(maximumFramesPerSecond: 120) {
      oneTwentyHertzRequests += 1
    }

    #expect(clock.requestFrame())
    #expect(sixtyHertzRequests == 0)
    #expect(oneTwentyHertzRequests == 1)

    // A surface appearing while a frame is pending must use the existing
    // election, including an equal-speed clock on another display.
    for framesPerSecond in [30, 120] {
      var lateSurfaceRequests = 0
      let late = clock.registerDriver(maximumFramesPerSecond: framesPerSecond) {
        lateSurfaceRequests += 1
      }
      #expect(lateSurfaceRequests == 0)
      clock.unregisterDriver(late)
    }
    #expect(oneTwentyHertzRequests == 3)

    let revision = clock.revision
    clock.didFire(sixty)
    #expect(clock.revision == revision)
    #expect(presentations == 0)
    clock.didFire(oneTwenty)
    #expect(clock.revision == revision + 1)
    #expect(presentations == 1)

    #expect(clock.requestFrame())
    clock.unregisterDriver(oneTwenty)
    #expect(sixtyHertzRequests == 1)
    clock.didFire(sixty)
    #expect(clock.revision == revision + 2)
    #expect(presentations == 2)
    clock.unregisterDriver(sixty)
  }

}

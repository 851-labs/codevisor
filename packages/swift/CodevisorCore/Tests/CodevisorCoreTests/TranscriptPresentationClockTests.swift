import Testing
@testable import CodevisorCore

@MainActor
@Suite("Transcript presentation clock")
struct TranscriptPresentationClockTests {
  @Test("The fastest visible display clock exclusively drives presentation")
  func fastestDisplayClockWins() {
    var presentations = 0
    let clock = makeClock { presentations += 1 }
    var sixtyHertzRequests = 0
    var oneTwentyHertzRequests = 0
    let sixty = clock.registerDriver(maximumFramesPerSecond: 60, isVisible: true) {
      sixtyHertzRequests += 1
    }
    let oneTwenty = clock.registerDriver(maximumFramesPerSecond: 120, isVisible: true) {
      oneTwentyHertzRequests += 1
    }

    #expect(clock.requestFrame())
    #expect(sixtyHertzRequests == 0)
    #expect(oneTwentyHertzRequests == 1)

    for framesPerSecond in [30, 120] {
      var lateSurfaceRequests = 0
      let late = clock.registerDriver(maximumFramesPerSecond: framesPerSecond, isVisible: true) {
        lateSurfaceRequests += 1
      }
      #expect(lateSurfaceRequests == 0)
      clock.unregisterDriver(late)
    }
    #expect(oneTwentyHertzRequests == 1)

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

  @Test("With no visible transcript, events apply immediately")
  func noVisibleTranscriptAppliesImmediately() {
    let session = Session()
    let clock = makeClock(session.apply)

    session.receive(1)
    clock.requestFrame()
    #expect(session.shown == [1])

    var closedWindowRequests = 0
    let closedWindow = clock.registerDriver(maximumFramesPerSecond: 60, isVisible: false) {
      closedWindowRequests += 1
    }
    session.receive(2)
    clock.requestFrame()
    #expect(session.shown == [1, 2])
    #expect(closedWindowRequests == 0)
    clock.unregisterDriver(closedWindow)
  }

  @Test("A visible transcript's next frame applies the batch, even beside a closed window")
  func visibleTranscriptFrameApplies() {
    let session = Session()
    let clock = makeClock(session.apply)
    var closedWindowRequests = 0
    let closedWindow = clock.registerDriver(maximumFramesPerSecond: 60, isVisible: true) {
      closedWindowRequests += 1
    }
    clock.setDriver(closedWindow, isVisible: false)
    var mainWindowRequests = 0
    let mainWindow = clock.registerDriver(maximumFramesPerSecond: 60, isVisible: true) {
      mainWindowRequests += 1
    }

    session.receive(1)
    session.receive(2)
    clock.requestFrame()
    #expect(session.shown.isEmpty)
    #expect(mainWindowRequests == 1)
    #expect(closedWindowRequests == 0)

    clock.didFire(closedWindow)
    #expect(session.shown.isEmpty)
    clock.didFire(mainWindow)
    #expect(session.shown == [1, 2])
    clock.unregisterDriver(mainWindow)
    clock.unregisterDriver(closedWindow)
  }

  @Test("A transcript that's hidden hands off its frame and shows the latest state once visible again")
  func hiddenTranscriptShowsLatestState() {
    let session = Session()
    let clock = makeClock(session.apply)
    var mainWindowRequests = 0
    let mainWindow = clock.registerDriver(maximumFramesPerSecond: 60, isVisible: true) {
      mainWindowRequests += 1
    }
    var transcriptWindowRequests = 0
    let transcriptWindow = clock.registerDriver(maximumFramesPerSecond: 60, isVisible: true) {
      transcriptWindowRequests += 1
    }

    session.receive(1)
    clock.requestFrame()
    #expect(mainWindowRequests == 1)
    clock.setDriver(mainWindow, isVisible: false)
    #expect(transcriptWindowRequests == 1)
    #expect(session.shown.isEmpty)
    clock.setDriver(transcriptWindow, isVisible: false)
    #expect(session.shown == [1])

    session.receive(2)
    clock.requestFrame()
    #expect(session.shown == [1, 2])

    clock.setDriver(mainWindow, isVisible: true)
    #expect(session.shown == [1, 2])
    #expect(mainWindowRequests == 1)

    session.receive(3)
    clock.requestFrame()
    #expect(mainWindowRequests == 2)
    #expect(session.shown == [1, 2])
    clock.didFire(mainWindow)
    #expect(session.shown == [1, 2, 3])
    clock.unregisterDriver(transcriptWindow)
    clock.unregisterDriver(mainWindow)
  }

  private func makeClock(_ present: @escaping () -> Void) -> TranscriptPresentationClock {
    TranscriptPresentationClock(present: present, preferPending: {}, onAppear: {}, onDisappear: {})
  }
}

@MainActor
private final class Session {
  private var pending: [Int] = []
  private(set) var shown: [Int] = []

  func receive(_ event: Int) {
    pending.append(event)
  }

  func apply() {
    shown += pending
    pending = []
  }
}

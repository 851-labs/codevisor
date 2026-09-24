import Testing

@testable import ScreenSharing

@Suite struct ScreenSharingWorkloadSequenceTests {
  @Test func drawsFollowTimeUntilFrozenAtTheLastDrawnCodeThenNeverAdvance() {
    var sequence = ScreenSharingWorkloadSequence(framesPerSecond: 60, startedAtSeconds: 100)
    #expect(sequence.drawn(atSeconds: 100) == 0)
    #expect(sequence.drawn(atSeconds: 100.5) == 30)
    #expect(sequence.drawn(atSeconds: 101) == 60)
    #expect(!sequence.isFrozen && sequence.lastDrawnCode == 60)
    sequence.freezeAtLastDrawn()
    #expect(sequence.isFrozen && sequence.frozenCode == 60)
    // Incidental redraws after the pause (window server requests, later
    // times, even earlier times) render and record the frozen code.
    #expect(sequence.drawn(atSeconds: 105) == 60)
    #expect(sequence.drawn(atSeconds: 130) == 60)
    #expect(sequence.drawn(atSeconds: 100) == 60)
    #expect(sequence.lastDrawnCode == 60)
  }

  @Test func pauseBetweenFramesFreezesWhatWasDrawnNotWhatTimeWouldSay() {
    var sequence = ScreenSharingWorkloadSequence(framesPerSecond: 60, startedAtSeconds: 100)
    #expect(sequence.drawn(atSeconds: 100.5) == 30)
    // The pause lands 29 frame periods later without any draw in between: a
    // time-derived code would be 59; the frozen code must be the drawn 30.
    sequence.freezeAtLastDrawn()
    #expect(sequence.frozenCode == 30)
    #expect(sequence.drawn(atSeconds: 100.99) == 30)
    #expect(sequence.drawn(atSeconds: 120) == 30)
  }

  @Test func timesBeforeStartClampToZeroAndFreezeBeforeAnyDrawHoldsZero() {
    var sequence = ScreenSharingWorkloadSequence(framesPerSecond: 30, startedAtSeconds: 50)
    #expect(sequence.drawn(atSeconds: 49) == 0)
    var undrawn = ScreenSharingWorkloadSequence(framesPerSecond: 30, startedAtSeconds: 50)
    undrawn.freezeAtLastDrawn()
    #expect(undrawn.frozenCode == 0 && undrawn.lastDrawnCode == nil)
    #expect(undrawn.drawn(atSeconds: 60) == 0)
  }
}

import Testing
@testable import ScreenSharing

struct ScreenSharingAdaptiveQualityTests {
  @Test func sustainedShortagePreservesTextBeforeReducingResolution() throws {
    var quality = ScreenSharingAdaptiveQuality(configuration: try .init())
    #expect(quality.update(availableBitrate: 2_000_000, now: 0) == nil)
    #expect(quality.update(availableBitrate: 2_000_000, now: 1.999) == nil)
    let slowerValue = quality.update(availableBitrate: 2_000_000, now: 2)
    let slower = try #require(slowerValue)
    #expect(slower.width == 1920 && slower.height == 1080 && slower.framesPerSecond == 30)
    #expect(quality.update(availableBitrate: 2_000_000, now: 3) == nil)
    let smallerValue = quality.update(availableBitrate: 2_000_000, now: 5)
    let smaller = try #require(smallerValue)
    #expect(smaller.width == 1440 && smaller.height == 810 && smaller.framesPerSecond == 30)
    #expect(quality.update(availableBitrate: 1_000_000, now: 6) == nil)
    let minimumValue = quality.update(availableBitrate: 1_000_000, now: 8)
    let minimum = try #require(minimumValue)
    #expect(minimum.width == 960 && minimum.height == 540 && minimum.framesPerSecond == 20)
    #expect(quality.update(availableBitrate: 100_000, now: 100) == nil)
  }

  @Test func recoveryNeedsContinuousHeadroomAndMissingSamplesResetTheDecision() throws {
    var quality = ScreenSharingAdaptiveQuality(configuration: try .init(width: 1512, height: 982))
    _ = quality.update(availableBitrate: 1_000_000, now: 0)
    _ = quality.update(availableBitrate: 1_000_000, now: 2)
    #expect(quality.update(availableBitrate: 12_000_000, now: 3) == nil)
    #expect(quality.update(availableBitrate: nil, now: 10) == nil)
    #expect(quality.update(availableBitrate: 12_000_000, now: 18) == nil)
    #expect(quality.update(availableBitrate: 12_000_000, now: 32.999) == nil)
    let restoredValue = quality.update(availableBitrate: 12_000_000, now: 33)
    let restored = try #require(restoredValue)
    #expect(restored.width == 1512 && restored.height == 982 && restored.framesPerSecond == 60)
    #expect(quality.update(availableBitrate: .nan, now: 100) == nil)
    #expect(quality.update(availableBitrate: .infinity, now: 100) == nil)
    #expect(quality.update(availableBitrate: -1, now: 100) == nil)
  }

  /// The two ends of the ladder. Level 0 has nothing to restore to and level 3 has nothing left to
  /// shed, so a persistent estimate at either end must simply stop producing configurations.
  @Test func theLadderStopsAtBothEndsAndWalksBackUpOneStepAtATime() throws {
    var quality = ScreenSharingAdaptiveQuality(configuration: try .init())
    #expect(quality.level == 0)
    for now in stride(from: 0.0, through: 60, by: 15) {
      #expect(quality.update(availableBitrate: 12_000_000, now: now) == nil)
    }
    #expect(quality.level == 0)

    // Down to the bottom: each step needs its own two seconds of shortage.
    for (start, expected) in [(61.0, 1), (63.0, 2), (66.0, 3)] {
      #expect(quality.update(availableBitrate: 500_000, now: start) == nil)
      let steppedValue = quality.update(availableBitrate: 500_000, now: start + 2)
      _ = try #require(steppedValue)
      #expect(quality.level == expected)
    }
    // At the bottom nothing lower exists, however bad the estimate gets.
    for now in [70.0, 80, 200] { #expect(quality.update(availableBitrate: 1, now: now) == nil) }
    #expect(quality.level == 3)

    // Back up: one step per fifteen seconds of headroom, never two at once.
    let restored = [(200.0, 215.0, 1440, 810, 30), (216, 231, 1920, 1080, 30), (232, 247, 1920, 1080, 60)]
    for (start, fires, width, height, fps) in restored {
      #expect(quality.update(availableBitrate: 12_000_000, now: start) == nil)
      #expect(quality.update(availableBitrate: 12_000_000, now: fires - 0.001) == nil)
      let configurationValue = quality.update(availableBitrate: 12_000_000, now: fires)
      let configuration = try #require(configurationValue)
      #expect((configuration.width, configuration.height, configuration.framesPerSecond) == (width, height, fps))
    }
    #expect(quality.level == 0)
  }

  /// The decision is elapsed time between samples, so a clock that jumps backwards must restart the
  /// window rather than let a stale start time fire a change immediately.
  @Test func aClockThatJumpsBackwardsRestartsTheWindowInsteadOfFiring() throws {
    var quality = ScreenSharingAdaptiveQuality(configuration: try .init())
    #expect(quality.update(availableBitrate: 2_000_000, now: 10) == nil)
    #expect(quality.update(availableBitrate: 2_000_000, now: 5) == nil)
    #expect(quality.update(availableBitrate: 2_000_000, now: 6.999) == nil)
    let firedValue = quality.update(availableBitrate: 2_000_000, now: 7)
    #expect(try #require(firedValue).framesPerSecond == 30)
    #expect(quality.level == 1)
    // A time that is not a time decides nothing and leaves no candidate behind.
    for now in [Double.nan, .infinity, -.infinity] {
      #expect(quality.update(availableBitrate: 12_000_000, now: now) == nil)
    }
    #expect(quality.update(availableBitrate: 12_000_000, now: 8) == nil)
    #expect(quality.update(availableBitrate: 12_000_000, now: 23) != nil)
    #expect(quality.level == 0)
  }

  /// An estimate between the two thresholds is not evidence for either direction: it abandons a
  /// pending change instead of letting it age toward one.
  @Test func anEstimateInsideTheBandAbandonsAPendingChange() throws {
    var quality = ScreenSharingAdaptiveQuality(configuration: try .init())
    #expect(quality.update(availableBitrate: 2_000_000, now: 0) == nil)
    // 70% of the target: too little to restore from, too much to call a shortage.
    #expect(quality.update(availableBitrate: 8_400_000, now: 1) == nil)
    #expect(quality.update(availableBitrate: 2_000_000, now: 2) == nil)
    #expect(quality.update(availableBitrate: 2_000_000, now: 3.999) == nil)
    #expect(quality.update(availableBitrate: 2_000_000, now: 4) != nil)
    #expect(quality.level == 1)
  }

  /// A candidate that changes direction starts its own window: a recovery that was nearly earned is
  /// abandoned by a collapse, and the collapse does not inherit the recovery's elapsed time.
  @Test func aCandidateThatChangesDirectionStartsItsWindowAgain() throws {
    var quality = ScreenSharingAdaptiveQuality(configuration: try .init())
    #expect(quality.update(availableBitrate: 2_000_000, now: 0) == nil)
    let loweredValue = quality.update(availableBitrate: 2_000_000, now: 2)
    #expect(try #require(loweredValue).framesPerSecond == 30)
    #expect(quality.update(availableBitrate: 12_000_000, now: 3) == nil)
    #expect(quality.update(availableBitrate: 12_000_000, now: 17) == nil)  // fourteen seconds of headroom
    #expect(quality.update(availableBitrate: 1_000_000, now: 18) == nil)  // the estimate collapses
    #expect(quality.update(availableBitrate: 12_000_000, now: 19) == nil)  // and comes back
    #expect(quality.update(availableBitrate: 12_000_000, now: 33.999) == nil)
    let recoveredValue = quality.update(availableBitrate: 12_000_000, now: 34)
    #expect(try #require(recoveredValue).framesPerSecond == 60)
    #expect(quality.level == 0)
  }
}

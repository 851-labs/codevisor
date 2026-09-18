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
}

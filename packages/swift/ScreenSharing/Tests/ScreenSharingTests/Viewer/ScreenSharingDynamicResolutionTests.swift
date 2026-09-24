import Foundation
import Testing
@testable import ScreenSharing

/// 851-2340: how many remote pixels per point Dynamic Resolution asks for.
struct ScreenSharingDynamicResolutionTests {
  @Test func aRetinaPaneGets2xUntilTheLinkSaysOtherwise() {
    var resolution = ScreenSharingDynamicResolution()
    #expect(resolution.scale(backingScale: 2, bitsPerSecond: nil) == 2, "unmeasured: trust the display")
    #expect(resolution.scale(backingScale: 2, bitsPerSecond: 50_000_000) == 2)
    #expect(resolution.scale(backingScale: 2, bitsPerSecond: 10_000_000) == 1, "below 15 Mbit/s")
    #expect(resolution.scale(backingScale: 2, bitsPerSecond: 20_000_000) == 1, "between the thresholds: stays")
    #expect(resolution.scale(backingScale: 2, bitsPerSecond: 30_000_000) == 2, "above 25 Mbit/s")
    #expect(resolution.scale(backingScale: 2, bitsPerSecond: 20_000_000) == 2, "between the thresholds: stays")
  }

  @Test func aOneXDisplayIsAlways1x() {
    var resolution = ScreenSharingDynamicResolution()
    #expect(resolution.scale(backingScale: 1, bitsPerSecond: 100_000_000) == 1)
    #expect(resolution.scale(backingScale: 1, bitsPerSecond: nil) == 1)
  }

  @Test func theLabelSaysWhatItDoesAndWhy() {
    #expect(
      ScreenSharingDynamicResolution.label(enabled: false, scale: 2, backingScale: 2, slowLink: false) == "fixed size")
    #expect(
      ScreenSharingDynamicResolution.label(enabled: true, scale: 2, backingScale: 2, slowLink: false) == "dynamic · 2×")
    #expect(
      ScreenSharingDynamicResolution.label(enabled: true, scale: 1, backingScale: 2, slowLink: true)
        == "dynamic · 1× (slow link)")
    #expect(
      ScreenSharingDynamicResolution.label(enabled: true, scale: nil, backingScale: 2, slowLink: false) == "dynamic")
  }
}

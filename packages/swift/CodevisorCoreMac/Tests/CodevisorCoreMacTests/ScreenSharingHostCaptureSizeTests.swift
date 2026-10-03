import Testing

@testable import CodevisorCoreMac

/// 851-2482: the physical display is captured scaled to fit 2560×1440, keeping its shape.
struct ScreenSharingHostCaptureSizeTests {
  @Test func displaysAreScaledToFitTheBoxAsAWhole() {
    let fit = ScreenSharingHostService.physicalCaptureSize
    #expect(fit(3024, 1964) == (2216, 1440), "a 14-inch MacBook Pro: the size measured on an M1 Pro")
    #expect(fit(5120, 2880) == (2560, 1440), "a 5K display")
    #expect(fit(1920, 1080) == (1920, 1080), "smaller displays aren't scaled up")
    #expect(fit(3456, 2234) == (2226, 1440))
  }
}

#if os(macOS)
  import Testing

  @testable import ScreenSharing

  @Suite struct ScreenSharingOfferedDrawableTests {
    @Test(arguments: [
      (takenAt: 10.000, usable: true),
      (takenAt: 10.008, usable: true),
      (takenAt: 10.0081, usable: false),
    ])
    func anOfferedDrawableServesFramesUntilHalfTheTimeToItsRefresh(takenAt: Double, usable: Bool) {
      var offered = ScreenSharingOfferedDrawable<Int>()
      offered.offer(1, now: 10, target: 10.016)
      #expect(offered.drawable(at: takenAt) == (usable ? 1 : nil))
    }

    @Test func anExpiredDrawableIsGoneEvenForAnEarlierClockAndANewOfferReplacesIt() {
      var offered = ScreenSharingOfferedDrawable<Int>()
      offered.offer(1, now: 10, target: 10.016)
      #expect(offered.drawable(at: 10.009) == nil)
      #expect(offered.drawable(at: 10.001) == nil)
      offered.offer(2, now: 10.016, target: 10.032)
      offered.offer(3, now: 10.032, target: 10.048)
      #expect(offered.drawable(at: 10.033) == 3)
      offered.release()
      #expect(offered.drawable(at: 10.033) == nil)
    }

    @Test func anOfferPastItsRefreshCannotBeUsed() {
      var offered = ScreenSharingOfferedDrawable<Int>()
      offered.offer(1, now: 10.02, target: 10.016)
      #expect(offered.drawable(at: 10.0201) == nil)
    }
  }
#endif

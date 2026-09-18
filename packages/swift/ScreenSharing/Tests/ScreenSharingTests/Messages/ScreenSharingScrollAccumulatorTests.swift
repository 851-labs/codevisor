import Testing

@testable import ScreenSharing

/// A trackpad reports fractional deltas; the wire carries whole pixels. The accumulator is the only
/// thing standing between the two, so what matters is that nothing is invented and nothing is lost:
/// every fraction is either emitted or retained for the next event.
struct ScreenSharingScrollAccumulatorTests {
  @Test func eachAxisCarriesItsOwnRemainder() {
    var scroll = ScreenSharingScrollAccumulator()
    #expect(scroll.add(x: 0.5, y: 0.25) == (0, 0))
    // x reaches a whole pixel while y is still half way; crossing one axis never flushes the other.
    #expect(scroll.add(x: 0.5, y: 0.25) == (1, 0))
    #expect(scroll.add(x: 0, y: 0.5) == (0, 1))
    #expect(scroll.add(x: 0, y: 0) == (0, 0))
  }

  /// Truncation runs toward zero on both sides, so a negative remainder has to be kept with its
  /// sign; rounding it away would make upward scrolling drift.
  @Test func negativeRemaindersAreKeptWithTheirSign() {
    var scroll = ScreenSharingScrollAccumulator()
    #expect(scroll.add(x: -0.5, y: -0.5) == (0, 0))
    #expect(scroll.add(x: -0.75, y: -0.25) == (-1, 0))
    #expect(scroll.add(x: -0.75, y: -0.25) == (-1, -1))
    // Reversing direction spends the remainder rather than discarding it.
    #expect(scroll.add(x: 0.5, y: 0) == (0, 0))
    #expect(scroll.add(x: 0.5, y: 0) == (1, 0))
  }

  @Test(arguments: [(3.0, -7.0), (1.0, 1.0), (-4096.0, 4096.0)])
  func wholeDeltasPassThroughWithoutARemainder(_ delta: (Double, Double)) {
    var scroll = ScreenSharingScrollAccumulator()
    #expect(scroll.add(x: delta.0, y: delta.1) == (Int32(delta.0), Int32(delta.1)))
    #expect(scroll.add(x: 0, y: 0) == (0, 0))
  }

  /// The clamp bounds one event, not the gesture: after the burst the accumulator has to be usable
  /// again immediately, or a fast flick would freeze scrolling.
  @Test func clampingBoundsOneEventAndLeavesNothingStuck() {
    var scroll = ScreenSharingScrollAccumulator()
    #expect(scroll.add(x: 1_000_000, y: -1_000_000) == (4096, -4096))
    #expect(scroll.add(x: 1, y: -1) == (1, -1))
    #expect(scroll.add(x: -1_000_000, y: 1_000_000) == (-4096, 4096))
    #expect(scroll.add(x: 0.5, y: 0.5) == (0, 0))
    #expect(scroll.add(x: 0.5, y: 0.5) == (1, 1))
    // Every clamped delta stays inside the range the wire format will accept.
    #expect(ScreenSharingInputEvent.scroll(.init(x: 0, y: 0), x: 4096, y: -4096, modifiers: 0).isValid)
  }

  /// A single non-finite component discards the whole update, including its finite partner: a NaN
  /// added to the running total would poison the axis for the rest of the session.
  @Test func oneNonFiniteComponentDropsTheWholeUpdateAndKeepsWhatWasPending() {
    for bad in [Double.nan, .infinity, -.infinity, .signalingNaN] {
      var scroll = ScreenSharingScrollAccumulator()
      #expect(scroll.add(x: 0.5, y: 0.5) == (0, 0))
      #expect(scroll.add(x: bad, y: 1) == (0, 0))
      #expect(scroll.add(x: 1, y: bad) == (0, 0))
      #expect(scroll.add(x: 0.5, y: 0.5) == (1, 1))
    }
  }

  /// The property the two callers depend on: across a gesture the emitted pixels track the deltas
  /// the trackpad reported, never running ahead of them or falling a whole pixel behind.
  @Test func aGestureEmitsEveryPixelItWasGivenAndNoMore() {
    var scroll = ScreenSharingScrollAccumulator()
    let deltas = (1...200).map { step -> (x: Double, y: Double) in
      (x: Double(step % 7) * 0.25 - 0.75, y: Double(step % 3) * 0.5)
    }
    var emitted = (x: 0.0, y: 0.0)
    var offered = (x: 0.0, y: 0.0)
    for delta in deltas {
      let pixels = scroll.add(x: delta.x, y: delta.y)
      offered = (offered.x + delta.x, offered.y + delta.y)
      emitted = (emitted.x + Double(pixels.x), emitted.y + Double(pixels.y))
      #expect(abs(offered.x - emitted.x) < 1 && abs(offered.y - emitted.y) < 1)
    }
  }
}

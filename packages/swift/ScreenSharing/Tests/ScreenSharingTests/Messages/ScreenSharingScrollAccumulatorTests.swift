import Testing

@testable import ScreenSharing

struct ScreenSharingScrollAccumulatorTests {
  @Test func eachAxisCarriesItsOwnRemainder() {
    var scroll = ScreenSharingScrollAccumulator()
    #expect(scroll.add(x: 0.5, y: 0.25) == (0, 0))
    #expect(scroll.add(x: 0.5, y: 0.25) == (1, 0))
    #expect(scroll.add(x: 0, y: 0.5) == (0, 1))
    #expect(scroll.add(x: 0, y: 0) == (0, 0))
  }

  @Test func negativeRemaindersAreKeptWithTheirSign() {
    var scroll = ScreenSharingScrollAccumulator()
    #expect(scroll.add(x: -0.5, y: -0.5) == (0, 0))
    #expect(scroll.add(x: -0.75, y: -0.25) == (-1, 0))
    #expect(scroll.add(x: -0.75, y: -0.25) == (-1, -1))
    #expect(scroll.add(x: 0.5, y: 0) == (0, 0))
    #expect(scroll.add(x: 0.5, y: 0) == (1, 0))
  }

  @Test(arguments: [(3.0, -7.0), (1.0, 1.0), (-4096.0, 4096.0)])
  func wholeDeltasPassThroughWithoutARemainder(_ delta: (Double, Double)) {
    var scroll = ScreenSharingScrollAccumulator()
    #expect(scroll.add(x: delta.0, y: delta.1) == (Int32(delta.0), Int32(delta.1)))
    #expect(scroll.add(x: 0, y: 0) == (0, 0))
  }

  @Test func clampingBoundsOneEventAndLeavesNothingStuck() {
    var scroll = ScreenSharingScrollAccumulator()
    #expect(scroll.add(x: 1_000_000, y: -1_000_000) == (4096, -4096))
    #expect(scroll.add(x: 1, y: -1) == (1, -1))
    #expect(scroll.add(x: -1_000_000, y: 1_000_000) == (-4096, 4096))
    #expect(scroll.add(x: 0.5, y: 0.5) == (0, 0))
    #expect(scroll.add(x: 0.5, y: 0.5) == (1, 1))
    #expect(ScreenSharingInputEvent.scroll(.init(x: 0, y: 0), x: 4096, y: -4096, modifiers: 0).isValid)
  }

  @Test func oneNonFiniteComponentDropsTheWholeUpdateAndKeepsWhatWasPending() {
    for bad in [Double.nan, .infinity, -.infinity, .signalingNaN] {
      var scroll = ScreenSharingScrollAccumulator()
      #expect(scroll.add(x: 0.5, y: 0.5) == (0, 0))
      #expect(scroll.add(x: bad, y: 1) == (0, 0))
      #expect(scroll.add(x: 1, y: bad) == (0, 0))
      #expect(scroll.add(x: 0.5, y: 0.5) == (1, 1))
    }
  }

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

#if canImport(AppKit)
  import CoreGraphics
  import Testing
  @testable import Autocomplete

  @Suite("Autocomplete popper placement")
  struct PopperPlacementTests {
    private typealias Placement = Autocomplete.PopperPlacement
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 240, height: 300)

    @Test("Opens below the trigger, leading-aligned, one native gap away")
    func below() {
      let anchor = CGRect(x: 100, y: 600, width: 80, height: 24)
      let placement = Placement.resolve(size: size, anchor: anchor, visibleFrame: screen)
      #expect(placement.edge == .below)
      #expect(placement.frame == CGRect(x: 100, y: 600 - Placement.nativeMenuGap - 300, width: 240, height: 300))
    }

    @Test("Flips above when the space below can't hold it")
    func flipsAbove() {
      let anchor = CGRect(x: 100, y: 120, width: 80, height: 24)
      let placement = Placement.resolve(size: size, anchor: anchor, visibleFrame: screen)
      #expect(placement.edge == .above)
      #expect(placement.frame.minY == anchor.maxY + Placement.nativeMenuGap)
    }

    @Test("Stays on screen horizontally and aligns to the trailing side in right-to-left layouts")
    func horizontal() {
      let nearRight = CGRect(x: 900, y: 600, width: 80, height: 24)
      let clamped = Placement.resolve(size: size, anchor: nearRight, visibleFrame: screen)
      #expect(clamped.frame.maxX == screen.maxX - Placement.screenInset)

      let nearLeft = CGRect(x: 300, y: 600, width: 80, height: 24)
      let rightToLeft = Placement.resolve(
        size: size, anchor: nearLeft, visibleFrame: screen, layoutDirection: .rightToLeft)
      #expect(rightToLeft.frame.maxX == nearLeft.maxX)
    }

    @Test("A resizing surface keeps the edge it opened on while that edge still fits")
    func keepsEdge() {
      let anchor = CGRect(x: 100, y: 400, width: 80, height: 24)
      let small = CGSize(width: 240, height: 100)
      let reopened = Placement.resolve(size: small, anchor: anchor, visibleFrame: screen)
      let resized = Placement.resolve(size: small, anchor: anchor, visibleFrame: screen, preferring: .above)
      #expect(reopened.edge == .below)
      #expect(resized.edge == .above)
    }

    @Test("The height available to a menu is the roomier side of the trigger")
    func availableHeight() {
      let anchor = CGRect(x: 100, y: 300, width: 80, height: 24)
      let available = Placement.availableHeight(anchor: anchor, visibleFrame: screen)
      #expect(available == screen.maxY - Placement.screenInset - anchor.maxY - Placement.nativeMenuGap)
    }

    @Test("Too tall for either side, it takes the roomier side and keeps its top on screen")
    func tooTall() {
      let anchor = CGRect(x: 100, y: 300, width: 80, height: 24)
      let tall = CGSize(width: 240, height: 900)
      let placement = Placement.resolve(size: tall, anchor: anchor, visibleFrame: screen)
      #expect(placement.edge == .above)
      #expect(placement.frame.maxY == screen.maxY - Placement.screenInset)
    }
  }
#endif

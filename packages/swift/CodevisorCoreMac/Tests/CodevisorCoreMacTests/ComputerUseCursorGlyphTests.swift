import CoreGraphics
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use cursor glyph in the live preview")
struct ComputerUseCursorGlyphTests {
  @Test("Scales with the card's zoom of the window")
  func zoom() {
    #expect(ComputerUseLivePreviewLayout.cursorScale(cardWidth: 640, windowWidth: 1000) == 0.64)
  }

  @Test("Clamps to a legibility floor and to the on-screen size")
  func clamps() {
    #expect(ComputerUseLivePreviewLayout.cursorScale(cardWidth: 200, windowWidth: 1600) == 0.5)
    #expect(ComputerUseLivePreviewLayout.cursorScale(cardWidth: 600, windowWidth: 400) == 1)
    #expect(ComputerUseLivePreviewLayout.cursorScale(cardWidth: 320, windowWidth: 0) == 1)
  }

  @Test("Uses the on-screen pointer artwork, flipped so the tip is at the top")
  func artwork() {
    let scale: CGFloat = 0.5
    let size = ComputerUseCursorGlyphShape.size(scale: scale)
    #expect(size == CGSize(width: 7.5, height: 8.5))
    let rect = CGRect(origin: .zero, size: size)
    let path = ComputerUseCursorGlyphShape().path(in: rect)
    let appKit = computerUsePointerArtwork(size: size)
    #expect(abs(path.boundingRect.width - appKit.cgPath.boundingBoxOfPath.width) < 0.001)
    #expect(abs(path.boundingRect.height - appKit.cgPath.boundingBoxOfPath.height) < 0.001)
    let tip = ComputerUseCursorGlyphShape.tip(scale: scale)
    #expect(abs(tip.y - (size.height - appKit.tip.y)) < 0.001)
    #expect(tip.y < size.height / 2)
    #expect(path.boundingRect.insetBy(dx: -0.01, dy: -0.01).contains(tip))
  }
}

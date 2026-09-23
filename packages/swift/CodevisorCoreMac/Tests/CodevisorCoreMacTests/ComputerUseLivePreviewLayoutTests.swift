import CoreGraphics
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use live preview corner snapping")
struct ComputerUseLivePreviewLayoutTests {
  private let container = CGSize(width: 1000, height: 800)
  private let card = CGSize(width: 320, height: 200)
  private let insets = ComputerUseLivePreviewInsets(top: 12, leading: 12, bottom: 112, trailing: 12)

  @Test("Bottom corners clear the composer's visible top edge")
  func composerAwareInsets() {
    // A 124 pt composer region is 100 pt of composer under 24 pt of padding.
    let insets = ComputerUseLivePreviewLayout.insets(composerHeight: 124)
    #expect(insets == ComputerUseLivePreviewInsets(top: 12, leading: 12, bottom: 112, trailing: 12))
    // No composer: an ordinary margin.
    #expect(ComputerUseLivePreviewLayout.insets(composerHeight: 0).bottom == 12)
  }

  @Test("Rests flush in each corner of the allowed area")
  func origins() {
    func origin(_ corner: ComputerUseLivePreviewCorner) -> CGPoint {
      ComputerUseLivePreviewLayout.origin(corner: corner, cardSize: card, container: container, insets: insets)
    }
    #expect(origin(.topLeading) == CGPoint(x: 12, y: 12))
    #expect(origin(.topTrailing) == CGPoint(x: 668, y: 12))
    #expect(origin(.bottomLeading) == CGPoint(x: 12, y: 488))
    #expect(origin(.bottomTrailing) == CGPoint(x: 668, y: 488))
  }

  @Test("A pane too small for the card pins it inside the allowed area")
  func tinyPane() {
    let origin = ComputerUseLivePreviewLayout.origin(
      corner: .bottomTrailing, cardSize: card, container: CGSize(width: 200, height: 150), insets: insets)
    #expect(origin == CGPoint(x: 12, y: 12))
  }

  @Test("Settles in the quadrant the release is heading for")
  func nearestCorner() {
    func corner(_ x: CGFloat, _ y: CGFloat) -> ComputerUseLivePreviewCorner {
      ComputerUseLivePreviewLayout.corner(
        projectedCenter: CGPoint(x: x, y: y), container: container, insets: insets)
    }
    // The allowed area's middle is (500, 350): the composer shifts it up.
    #expect(corner(100, 100) == .topLeading)
    #expect(corner(900, 100) == .topTrailing)
    #expect(corner(100, 600) == .bottomLeading)
    #expect(corner(900, 600) == .bottomTrailing)
    #expect(corner(900, 360) == .bottomTrailing)
    // A flick projects far past the pane but still picks the corner it aims at.
    #expect(corner(-4000, 5000) == .bottomLeading)
  }
}

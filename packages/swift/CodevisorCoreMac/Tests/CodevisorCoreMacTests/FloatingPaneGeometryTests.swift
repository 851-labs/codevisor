import CoreGraphics
import Testing
@testable import CodevisorCoreMac

@Suite("Floating pane geometry")
struct FloatingPaneGeometryTests {
  private let container = CGSize(width: 1000, height: 800)

  @Test("New panes open top right and cascade")
  func defaultFrames() {
    #expect(
      FloatingPaneGeometry.defaultFrame(index: 0, container: container)
        == CGRect(x: 568, y: 12, width: 420, height: 480))
    #expect(
      FloatingPaneGeometry.defaultFrame(index: 1, container: container)
        == CGRect(x: 540, y: 40, width: 420, height: 480))
  }

  @Test("Dragging past an edge keeps the pane inside the content area")
  func moveClamps() {
    let frame = CGRect(x: 100, y: 100, width: 300, height: 200)

    let moved = FloatingPaneGeometry.moved(frame, by: CGSize(width: 2000, height: -500), container: container)

    #expect(moved == CGRect(x: 688, y: 12, width: 300, height: 200))
  }

  @Test("A shrinking window re-clamps both size and position")
  func clampToSmallerWindow() {
    let frame = CGRect(x: 600, y: 500, width: 420, height: 480)

    let clamped = FloatingPaneGeometry.clamped(frame, container: CGSize(width: 500, height: 400))

    #expect(clamped == CGRect(x: 68, y: 12, width: 420, height: 376))
  }

  @Test("Dropping near an edge snaps flush to it")
  func snapping() {
    let near = CGRect(x: 25, y: 200, width: 300, height: 200)
    let far = CGRect(x: 100, y: 200, width: 300, height: 200)
    let nearTrailing = CGRect(x: 680, y: 200, width: 300, height: 200)

    #expect(FloatingPaneGeometry.snapped(near, container: container).minX == 12)
    #expect(FloatingPaneGeometry.snapped(far, container: container) == far)
    #expect(FloatingPaneGeometry.snapped(nearTrailing, container: container).maxX == 988)
  }

  @Test("Resizing from a corner stops at the minimum size and the content edge")
  func resizing() {
    let frame = CGRect(x: 100, y: 100, width: 400, height: 300)

    let shrunk = FloatingPaneGeometry.resized(
      frame, handle: .topLeading, translation: CGSize(width: 500, height: 500), container: container)
    let grown = FloatingPaneGeometry.resized(
      frame, handle: .bottomTrailing, translation: CGSize(width: 2000, height: 2000), container: container)

    #expect(shrunk == CGRect(x: 220, y: 220, width: 280, height: 180))
    #expect(grown == CGRect(x: 100, y: 100, width: 888, height: 688))
  }

  @Test("A content area smaller than a minimum pane has no room for one")
  func fits() {
    #expect(FloatingPaneGeometry.fits(in: container))
    #expect(!FloatingPaneGeometry.fits(in: .zero))
  }
}

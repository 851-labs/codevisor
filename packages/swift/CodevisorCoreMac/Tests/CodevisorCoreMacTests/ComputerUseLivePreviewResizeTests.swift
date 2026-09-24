import CoreGraphics
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use live preview resizing")
struct ComputerUseLivePreviewResizeTests {
  private typealias Layout = ComputerUseLivePreviewLayout
  // 976 × 776 available; 60% of the width is 585.6 pt.
  private let container = CGSize(width: 1000, height: 800)
  private let insets = ComputerUseLivePreviewInsets(top: 12, leading: 12, bottom: 12, trailing: 12)

  private func size(_ area: CGFloat, _ aspect: CGFloat, in container: CGSize? = nil) -> CGSize {
    Layout.size(area: area, aspect: aspect, container: container ?? self.container, insets: insets)
  }

  @Test("Starts at today's default: aspect-fit into 320 × 260")
  func defaultSize() {
    #expect(abs(Layout.defaultArea(aspect: 1.6) - 320 * 200) < 0.01)
    #expect(size(Layout.defaultArea(aspect: 1.6), 1.6) == CGSize(width: 320, height: 200))
    #expect(size(Layout.defaultArea(aspect: 0.8), 0.8) == CGSize(width: 208, height: 260))
  }

  @Test("Never smaller than the minimum sides")
  func minimum() {
    #expect(size(1, 1.6) == CGSize(width: 200, height: 125))
    #expect(size(1, 0.5) == CGSize(width: 120, height: 240))
  }

  @Test("Never wider than 60% of the pane or taller than the space above the composer")
  func maximum() {
    #expect(size(10_000_000, 1.6) == CGSize(width: 586, height: 366))
    // A short pane: height is the binding limit.
    let composer = ComputerUseLivePreviewInsets(top: 12, leading: 12, bottom: 500, trailing: 12)
    let clamped = Layout.size(area: 10_000_000, aspect: 1.6, container: container, insets: composer)
    #expect(clamped == CGSize(width: 461, height: 288))
  }

  @Test("Keeps about the same area when the window switches between landscape and portrait")
  func aspectChange() {
    let area = size(Layout.defaultArea(aspect: 1.6), 1.6)
    let portrait = size(area.width * area.height, 0.5)
    #expect(portrait == CGSize(width: 179, height: 358))
  }

  @Test("Extreme aspects letterbox inside the limits instead of becoming a sliver")
  func extremeAspects() {
    #expect(size(64_000, 10) == CGSize(width: 586, height: 120))
    #expect(size(64_000, 0.1) == CGSize(width: 120, height: 776))
  }

  @Test("Dragging a handle outward grows the card with its aspect locked")
  func handles() {
    let start = CGSize(width: 320, height: 200)
    func width(_ handle: ComputerUseLivePreviewResizeHandle, _ dx: CGFloat, _ dy: CGFloat) -> CGFloat {
      let area = Layout.resizedArea(
        handle: handle, startSize: start, translation: CGSize(width: dx, height: dy), aspect: 1.6)
      return (area * 1.6).squareRoot().rounded()
    }
    #expect(width(.trailing, 80, 0) == 400)
    #expect(width(.leading, -80, 0) == 400)
    #expect(width(.leading, 80, 0) == 240)
    #expect(width(.bottom, 0, 50) == 400)
    #expect(width(.top, 0, -50) == 400)
    // A vertical drag on a side handle is ignored.
    #expect(width(.trailing, 0, 300) == 320)
    // Corners follow the axis that moved further.
    #expect(width(.topLeading, -30, -100) == 480)
    #expect(width(.bottomTrailing, 100, 10) == 420)
  }

  @Test("Viewers raise the capture resolution, within a ceiling")
  func captureDimension() {
    #expect(computerUseNativePreviewMaximumDimension(requestedDimension: 0) == 960)
    #expect(computerUseNativePreviewMaximumDimension(requestedDimension: 1172.4) == 1173)
    #expect(computerUseNativePreviewMaximumDimension(requestedDimension: 5000) == 1920)
    let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let sharp = computerUseNativePreviewSettings(
      windowFrame: frame, pointPixelScale: 2, viewerCount: 1, requestedDimension: 1400)
    #expect(sharp.size == CGSize(width: 1400, height: 932))
  }
}

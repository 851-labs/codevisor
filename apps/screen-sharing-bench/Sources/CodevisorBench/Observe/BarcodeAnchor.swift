import ScreenCaptureKit
import ScreenSharingBench

enum BarcodeAnchor: String, CaseIterable {
  case top
  case bottom

  @MainActor
  func layout(_ layout: BenchBarcodeLayout, on display: SCDisplay) -> BenchBarcodeLayout {
    switch self {
    case .top: return layout
    case .bottom:
      let scale = CGFloat(SCContentFilter(display: display, excludingWindows: []).pointPixelScale)
      let height = Int((CGFloat(display.height) * scale).rounded())
      return BenchBarcodeLayout(x: layout.x, y: max(0, height - layout.height - layout.y), blockSize: layout.blockSize)
    }
  }
}

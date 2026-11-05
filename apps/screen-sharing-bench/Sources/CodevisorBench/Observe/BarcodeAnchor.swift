import ScreenSharingBench

enum BarcodeAnchor: String, CaseIterable {
  case top
  case bottom

  func layout(_ layout: BenchBarcodeLayout, displayPixelHeight height: Int) throws -> BenchBarcodeLayout {
    switch self {
    case .top: return layout
    case .bottom:
      let y = height - layout.height - layout.y
      guard y >= 0 else {
        throw BenchUsageError(message: "--barcode-y \(layout.y) puts the bottom barcode above a \(height) px display")
      }

      return BenchBarcodeLayout(x: layout.x, y: y, blockSize: layout.blockSize)
    }
  }
}

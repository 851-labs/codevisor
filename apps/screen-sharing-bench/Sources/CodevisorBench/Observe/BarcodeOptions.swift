import ScreenSharingBench

@MainActor
enum BarcodeOptions {
  static let usage = "[--barcode-x <px>] [--barcode-y <px>] [--block-size <px>]"

  private static let coordinates = 0...16_384
  private static let blockSizes = BenchBarcodeLayout.minimumBlockSize...256

  static func layout(from options: BenchOptions) throws -> BenchBarcodeLayout {
    let standard = BenchBarcodeLayout.standard
    return BenchBarcodeLayout(
      x: try options.integer("barcode-x", default: standard.x, in: coordinates),
      y: try options.integer("barcode-y", default: standard.y, in: coordinates),
      blockSize: try options.integer("block-size", default: standard.blockSize, in: blockSizes))
  }
}

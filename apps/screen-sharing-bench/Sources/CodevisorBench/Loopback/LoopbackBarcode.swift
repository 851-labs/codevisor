import CoreVideo
import ScreenSharingBench

enum LoopbackBarcode {
  static func version(in pixelBuffer: CVPixelBuffer, canvasWidth: Int) -> Int? {
    let layout = BenchBarcodeLayout(
      blockSize: BenchBarcodeLayout.standard.blockSize * CVPixelBufferGetWidth(pixelBuffer) / canvasWidth)
    guard case .version(let version) = try? BenchBarcode.read(pixelBuffer, layout: layout) else { return nil }

    return version
  }
}

import CoreVideo
import Metal

struct BenchBarcodeImage {
  private static let bytesPerPixel = MemoryLayout<UInt32>.size
  private static let darkBGRA: UInt32 = 0xFF00_0000
  private static let lightBGRA: UInt32 = 0xFFFF_FFFF

  private let layout: BenchBarcodeLayout
  private let dataRow: [UInt32]
  private let complementRow: [UInt32]

  init(version: Int, layout: BenchBarcodeLayout) throws {
    guard BenchBarcode.versions.contains(version) else { throw BenchBarcodeError.versionOutOfRange(version) }

    let word = BenchBarcodeWord(version: version)
    self.layout = layout
    dataRow = Self.row(of: word, blockSize: layout.blockSize, isComplement: false)
    complementRow = Self.row(of: word, blockSize: layout.blockSize, isComplement: true)
  }

  func copy(into pixelBuffer: CVPixelBuffer) throws {
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    guard format == kCVPixelFormatType_32BGRA else { throw BenchBarcodeError.unsupportedPixelFormat(format) }
    guard layout.fits(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)) else {
      throw BenchBarcodeError.layoutOutsideImage
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw BenchBarcodeError.pixelsUnavailable }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for row in 0..<layout.height {
      let target = base + (layout.y + row) * bytesPerRow + layout.x * Self.bytesPerPixel
      scanline(row).withUnsafeBytes { target.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }
  }

  func copy(into texture: any MTLTexture) throws {
    guard texture.pixelFormat == .bgra8Unorm else {
      throw BenchBarcodeError.unsupportedTextureFormat(texture.pixelFormat)
    }
    guard isWritableFromCPU(texture) else { throw BenchBarcodeError.textureNotWritableFromCPU }
    guard layout.fits(width: texture.width, height: texture.height) else { throw BenchBarcodeError.layoutOutsideImage }

    let pixels = (0..<layout.height).flatMap(scanline)
    let region = MTLRegionMake2D(layout.x, layout.y, layout.width, layout.height)
    pixels.withUnsafeBytes {
      texture.replace(
        region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: layout.width * Self.bytesPerPixel)
    }
  }

  private func isWritableFromCPU(_ texture: any MTLTexture) -> Bool {
    texture.storageMode != .private && !texture.isFramebufferOnly
  }

  private func scanline(_ row: Int) -> [UInt32] {
    row < layout.blockSize ? dataRow : complementRow
  }

  private static func row(of word: BenchBarcodeWord, blockSize: Int, isComplement: Bool) -> [UInt32] {
    var row = [UInt32](repeating: darkBGRA, count: blockSize * BenchBarcode.blockCount)
    row.withUnsafeMutableBufferPointer { pixels in
      for block in 0..<BenchBarcode.blockCount where word.isLight(block: block) != isComplement {
        let start = block * blockSize
        UnsafeMutableBufferPointer(rebasing: pixels[start..<start + blockSize]).update(repeating: lightBGRA)
      }
    }
    return row
  }
}

import CoreVideo
import Metal

public enum BenchBarcode {
  public static let versions: ClosedRange<Int> = 0...0xFF_FFFF
  public static let blockCount = 32

  public static func draw(
    _ version: Int, into pixelBuffer: CVPixelBuffer, layout: BenchBarcodeLayout = .standard
  ) throws {
    try BenchBarcodeImage(version: version, layout: layout).copy(into: pixelBuffer)
  }

  public static func draw(
    _ version: Int, into texture: any MTLTexture, layout: BenchBarcodeLayout = .standard
  ) throws {
    try BenchBarcodeImage(version: version, layout: layout).copy(into: texture)
  }

  public static func read(
    _ pixelBuffer: CVPixelBuffer, layout: BenchBarcodeLayout = .standard
  ) throws -> BenchBarcodeReading {
    try BenchLumaPlane.withPlane(of: pixelBuffer) { plane in
      try plane.require(layout)
      return BenchBarcodeReader(plane: plane, layout: layout).reading()
    }
  }
}

public enum BenchBarcodeReading: Sendable, Equatable {
  case version(Int)
  case ambiguousBlock(Int)
  case checksumMismatch
}

public enum BenchBarcodeError: Error, Equatable {
  case unsupportedPixelFormat(OSType)
  case unsupportedTextureFormat(MTLPixelFormat)
  case textureNotWritableFromCPU
  case versionOutOfRange(Int)
  case layoutOutsideImage
  case pixelsUnavailable
}

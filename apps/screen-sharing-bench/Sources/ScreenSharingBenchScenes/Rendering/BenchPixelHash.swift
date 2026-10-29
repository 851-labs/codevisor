import CoreVideo
import CryptoKit

public enum BenchPixelHash {
  private static let bytesPerPixel = 4

  public static func bgra(_ base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) -> String {
    var hasher = SHA256()
    for row in 0..<height {
      hasher.update(
        bufferPointer: UnsafeRawBufferPointer(start: base + row * bytesPerRow, count: width * bytesPerPixel))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public static func bgra(_ pixelBuffer: CVPixelBuffer) throws -> String {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw BenchSceneError.textureUnavailable }

    return bgra(
      base, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer))
  }
}

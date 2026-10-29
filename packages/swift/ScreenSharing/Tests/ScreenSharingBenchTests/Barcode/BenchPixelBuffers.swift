import Accelerate
import CoreVideo
import ScreenSharingBench
import VideoToolbox

enum BenchPixelBuffers {
  static func make(width: Int, height: Int, format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
    let attributes: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw BenchPixelBufferError.creationFailed(status) }

    return buffer
  }

  static func fill(_ buffer: CVPixelBuffer, gray: UInt8) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let bytes = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
    CVPixelBufferGetBaseAddress(buffer)!.initializeMemory(as: UInt8.self, repeating: gray, count: bytes)
  }

  static func copyColumns(_ columns: Range<Int>, rows: Range<Int>, from source: CVPixelBuffer, to target: CVPixelBuffer)
  {
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(target, [])
    defer {
      CVPixelBufferUnlockBaseAddress(target, [])
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(source)
    for row in rows {
      let offset = row * bytesPerRow + columns.lowerBound * 4
      (CVPixelBufferGetBaseAddress(target)! + offset).copyMemory(
        from: CVPixelBufferGetBaseAddress(source)! + offset, byteCount: columns.count * 4)
    }
  }

  static func addNoise(to buffer: CVPixelBuffer, from noise: BenchNoise, random: inout SplitMix64) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
      let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
      let pixels = UnsafeMutableBufferPointer(
        start: CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self), count: bytes)
      noise.add(to: pixels, random: &random)
    }
  }
}

struct BenchNoise {
  private static let chunk = 1 << 16

  private let values: [Float]

  init(amplitude: Int, count: Int, random: inout SplitMix64) {
    let span = UInt64(2 * amplitude + 1)
    values = (0..<count).map { _ in Float(Int(random.next() % span) - amplitude) }
  }

  func add(to pixels: UnsafeMutableBufferPointer<UInt8>, random: inout SplitMix64) {
    var levels = [Float](repeating: 0, count: Self.chunk)
    for start in stride(from: 0, to: pixels.count, by: Self.chunk) {
      let length = min(Self.chunk, pixels.count - start)
      let offset = Int(random.next() % UInt64(values.count - length))
      add(to: pixels.baseAddress! + start, length: length, noiseOffset: offset, levels: &levels)
    }
  }

  private func add(to pixels: UnsafeMutablePointer<UInt8>, length: Int, noiseOffset: Int, levels: inout [Float]) {
    var black: Float = 0
    var white: Float = 255
    let count = vDSP_Length(length)
    values.withUnsafeBufferPointer { noise in
      vDSP_vfltu8(pixels, 1, &levels, 1, count)
      vDSP_vadd(levels, 1, noise.baseAddress! + noiseOffset, 1, &levels, 1, count)
      vDSP_vclip(levels, 1, &black, &white, &levels, 1, count)
      vDSP_vfixru8(levels, 1, pixels, 1, count)
    }
  }
}

struct BenchPixelTransfer {
  private let session: VTPixelTransferSession

  init() throws {
    var session: VTPixelTransferSession?
    let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
    guard status == noErr, let session else { throw BenchPixelBufferError.transferFailed(status) }

    VTSessionSetProperty(
      session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    self.session = session
  }

  func transfer(_ source: CVPixelBuffer, to destination: CVPixelBuffer) throws {
    let status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
    guard status == noErr else { throw BenchPixelBufferError.transferFailed(status) }
  }
}

enum BenchPixelBufferError: Error {
  case creationFailed(CVReturn)
  case transferFailed(OSStatus)
}

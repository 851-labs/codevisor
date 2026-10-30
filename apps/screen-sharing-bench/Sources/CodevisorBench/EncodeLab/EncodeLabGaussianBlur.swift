import Accelerate
import Foundation

struct EncodeLabGaussianBlur {
  static let radius = 5
  static let sigma: Float = 1.5
  static let kernel: [Float] = {
    let weights = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
    let sum = weights.reduce(0, +)
    return weights.map { $0 / sum }
  }()

  let width: Int
  let height: Int

  func apply(_ plane: [Float]) throws -> [Float] {
    var input = plane
    var output = [Float](repeating: 0, count: plane.count)
    let status = input.withUnsafeMutableBytes { source in
      output.withUnsafeMutableBytes { target in
        var sourceBuffer = buffer(source)
        var targetBuffer = buffer(target)
        return vImageSepConvolve_PlanarF(
          &sourceBuffer, &targetBuffer, nil, 0, 0, Self.kernel, UInt32(Self.kernel.count), Self.kernel,
          UInt32(Self.kernel.count), 0, 0, vImage_Flags(kvImageEdgeExtend))
      }
    }
    guard status == kvImageNoError else { throw EncodeLabError.transfer("blur", Int32(status)) }

    return output
  }

  private func buffer(_ bytes: UnsafeMutableRawBufferPointer) -> vImage_Buffer {
    vImage_Buffer(
      data: bytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
      rowBytes: width * MemoryLayout<Float>.stride)
  }
}

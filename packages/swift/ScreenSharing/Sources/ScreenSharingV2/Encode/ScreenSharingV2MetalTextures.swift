import CoreVideo
@preconcurrency import Metal
import ScreenSharing

final class ScreenSharingV2MetalTextures: @unchecked Sendable {
  static let planeFormats: [OSType: [MTLPixelFormat]] = [
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: [.r8Unorm, .rg8Unorm],
    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: [.r8Unorm, .rg8Unorm],
    kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange: [.r8Unorm, .rg8Unorm],
    kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: [.r8Unorm, .rg8Unorm],
    kCVPixelFormatType_32BGRA: [.bgra8Unorm],
  ]

  let device: any MTLDevice
  private let cache: CVMetalTextureCache

  init(device: any MTLDevice) throws {
    var cache: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
      throw ScreenSharingError.unavailable("No Metal texture cache.")
    }

    self.device = device
    self.cache = cache
  }

  func planes(
    of pixels: CVPixelBuffer, usage: MTLTextureUsage = .shaderRead, retaining retained: inout [CVMetalTexture]
  ) throws -> [any MTLTexture] {
    let pixelFormat = CVPixelBufferGetPixelFormatType(pixels)
    guard let formats = Self.planeFormats[pixelFormat] else {
      throw ScreenSharingError.invalid("No Metal texture format for pixel format \(pixelFormat).")
    }

    return try formats.enumerated().map { plane, format in
      try texture(pixels, plane: plane, format: format, usage: usage, retaining: &retained)
    }
  }

  func flush() {
    CVMetalTextureCacheFlush(cache, 0)
  }

  private func texture(
    _ pixels: CVPixelBuffer, plane: Int, format: MTLPixelFormat, usage: MTLTextureUsage,
    retaining retained: inout [CVMetalTexture]
  ) throws -> any MTLTexture {
    let planar = CVPixelBufferIsPlanar(pixels)
    let width = planar ? CVPixelBufferGetWidthOfPlane(pixels, plane) : CVPixelBufferGetWidth(pixels)
    let height = planar ? CVPixelBufferGetHeightOfPlane(pixels, plane) : CVPixelBufferGetHeight(pixels)
    let attributes = [kCVMetalTextureUsage: usage.rawValue] as CFDictionary
    var created: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      nil, cache, pixels, attributes, format, width, height, plane, &created)
    guard status == kCVReturnSuccess, let created, let texture = CVMetalTextureGetTexture(created) else {
      throw ScreenSharingError.codec("Map a pixel buffer plane to Metal", status)
    }

    retained.append(created)
    return texture
  }
}

import Foundation
import CoreVideo
@preconcurrency import Metal
import ScreenSharing
import Synchronization
import VideoToolbox

final class ScreenSharingVCPPixelConverter: @unchecked Sendable {
  static let encodedPixelFormat = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
  private static var colorTags: [(CFString, CFString)] {
    [
      (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
      (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB),
      (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
    ]
  }
  private struct Conversion: @unchecked Sendable {
    let capture: Int64
    let target: CVPixelBuffer
  }

  private let kernel: ScreenSharingVCPConversionKernel
  private let cache: CVMetalTextureCache
  private let pool: CVPixelBufferPool
  private let size: (width: Int, height: Int)
  private let scalerLock = NSLock()
  private var scaler: VTPixelTransferSession?
  private let last = Mutex<Conversion?>(nil)

  init(width: Int, height: Int) throws {
    kernel = try ScreenSharingVCPConversionKernel.shared()
    var cache: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(nil, nil, kernel.device, nil, &cache) == kCVReturnSuccess, let cache else {
      throw ScreenSharingError.unavailable("No Metal texture cache for the VCP converter.")
    }

    self.cache = cache
    size = (width, height)
    pool = try Self.pool(width: width, height: height)
  }

  deinit {
    if let scaler { VTPixelTransferSessionInvalidate(scaler) }
  }

  func convert(_ source: CVPixelBuffer, capture: Int64) throws -> CVPixelBuffer {
    guard CVPixelBufferGetPixelFormatType(source) != Self.encodedPixelFormat else { return source }
    if let repeated = last.withLock({ $0?.capture == capture ? $0?.target : nil }) { return repeated }

    let target = try transfer(source)
    last.withLock { $0 = Conversion(capture: capture, target: target) }
    return target
  }

  private func transfer(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
    guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else {
      throw ScreenSharingError.invalid("The VCP converter takes BGRA captures.")
    }

    var created: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
    guard status == kCVReturnSuccess, let target = created else {
      throw ScreenSharingError.codec("Allocate VCP input", status)
    }

    if CVPixelBufferGetWidth(source) == size.width && CVPixelBufferGetHeight(source) == size.height {
      try convertExactly(source, into: target)
    } else {
      try scale(source, into: target)
    }
    for (key, value) in Self.colorTags { CVBufferSetAttachment(target, key, value, .shouldPropagate) }
    return target
  }

  private func convertExactly(_ source: CVPixelBuffer, into target: CVPixelBuffer) throws {
    var retained: [CVMetalTexture] = []
    try kernel.run(
      source: try texture(source, plane: 0, format: .bgra8Unorm, retaining: &retained),
      luma: try texture(target, plane: 0, format: .r8Unorm, retaining: &retained),
      chroma: try texture(target, plane: 1, format: .rg8Unorm, retaining: &retained))
    withExtendedLifetime(retained) {}
    CVMetalTextureCacheFlush(cache, 0)
  }

  private func scale(_ source: CVPixelBuffer, into target: CVPixelBuffer) throws {
    try scalerLock.withLock {
      let session = try scaler ?? Self.scalingSession()
      scaler = session
      let status = VTPixelTransferSessionTransferImage(session, from: source, to: target)
      guard status == noErr else { throw ScreenSharingError.codec("Scale VCP input", status) }
    }
  }

  private static func scalingSession() throws -> VTPixelTransferSession {
    var session: VTPixelTransferSession?
    let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
    guard status == noErr, let session else { throw ScreenSharingError.codec("Create VCP scaler", status) }

    VTSessionSetProperty(
      session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    return session
  }

  private func texture(
    _ pixels: CVPixelBuffer, plane: Int, format: MTLPixelFormat, retaining retained: inout [CVMetalTexture]
  ) throws -> any MTLTexture {
    let planar = CVPixelBufferIsPlanar(pixels)
    let width = planar ? CVPixelBufferGetWidthOfPlane(pixels, plane) : CVPixelBufferGetWidth(pixels)
    let height = planar ? CVPixelBufferGetHeightOfPlane(pixels, plane) : CVPixelBufferGetHeight(pixels)
    let attributes = [kCVMetalTextureUsage: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue] as CFDictionary
    var created: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      nil, cache, pixels, attributes, format, width, height, plane, &created)
    guard status == kCVReturnSuccess, let created, let texture = CVMetalTextureGetTexture(created) else {
      throw ScreenSharingError.codec("Map a VCP converter texture", status)
    }

    retained.append(created)
    return texture
  }

  private static func pool(width: Int, height: Int) throws -> CVPixelBufferPool {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: encodedPixelFormat, kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw ScreenSharingError.codec("Create VCP input pool", status) }

    return pool
  }
}

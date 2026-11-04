import CoreVideo
@preconcurrency import Metal
import ScreenSharing
import Synchronization

final class ScreenSharingVCPPixelConverter: @unchecked Sendable {
  static let encodedPixelFormat = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
  private static var colorTags: [(CFString, CFString)] {
    [
      (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
      (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB),
      (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
    ]
  }
  private static let threadgroup = MTLSize(width: 16, height: 16, depth: 1)
  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void bgraTo444(texture2d<float, access::read> source [[texture(0)]],
                          texture2d<float, access::write> luma [[texture(1)]],
                          texture2d<float, access::write> chroma [[texture(2)]],
                          uint2 position [[thread_position_in_grid]]) {
      if (position.x >= luma.get_width() || position.y >= luma.get_height()) { return; }
      float3 rgb = source.read(position).rgb;
      float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
      float cb = (rgb.b - y) / 1.8556 + 128.0 / 255.0;
      float cr = (rgb.r - y) / 1.5748 + 128.0 / 255.0;
      luma.write(float4(y), position);
      chroma.write(float4(cb, cr, 0.0, 0.0), position);
    }
    """

  private struct Conversion: @unchecked Sendable {
    let capture: Int64
    let target: CVPixelBuffer
  }

  private let cache: CVMetalTextureCache
  private let queue: any MTLCommandQueue
  private let pipeline: any MTLComputePipelineState
  private let pool: CVPixelBufferPool
  private let last = Mutex<Conversion?>(nil)

  init(width: Int, height: Int) throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw ScreenSharingError.unavailable("Metal is unavailable for the VCP converter.")
    }

    var cache: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
      throw ScreenSharingError.unavailable("No Metal texture cache for the VCP converter.")
    }

    self.cache = cache
    self.queue = queue
    pipeline = try Self.pipeline(device)
    pool = try Self.pool(width: width, height: height)
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

    var retained: [CVMetalTexture] = []
    try encode(
      source: try texture(source, plane: 0, format: .bgra8Unorm, retaining: &retained),
      luma: try texture(target, plane: 0, format: .r8Unorm, retaining: &retained),
      chroma: try texture(target, plane: 1, format: .rg8Unorm, retaining: &retained))
    withExtendedLifetime(retained) {}
    CVMetalTextureCacheFlush(cache, 0)
    for (key, value) in Self.colorTags { CVBufferSetAttachment(target, key, value, .shouldPropagate) }
    return target
  }

  private func encode(source: any MTLTexture, luma: any MTLTexture, chroma: any MTLTexture) throws {
    guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else {
      throw ScreenSharingError.unavailable("No Metal command buffer for the VCP converter.")
    }

    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(source, index: 0)
    encoder.setTexture(luma, index: 1)
    encoder.setTexture(chroma, index: 2)
    encoder.dispatchThreads(
      MTLSize(width: luma.width, height: luma.height, depth: 1), threadsPerThreadgroup: Self.threadgroup)
    encoder.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
    guard buffer.status == .completed else {
      throw ScreenSharingError.unavailable("The VCP conversion failed: \(buffer.error?.localizedDescription ?? "?")")
    }
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

  private static func pipeline(_ device: any MTLDevice) throws -> any MTLComputePipelineState {
    let library = try device.makeLibrary(source: shader, options: nil)
    guard let function = library.makeFunction(name: "bgraTo444") else {
      throw ScreenSharingError.unavailable("No VCP conversion kernel.")
    }

    return try device.makeComputePipelineState(function: function)
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

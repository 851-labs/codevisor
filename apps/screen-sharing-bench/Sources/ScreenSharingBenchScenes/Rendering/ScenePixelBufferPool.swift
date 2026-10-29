import CoreVideo
import Metal

struct ScenePixelBufferPool {
  struct Frame {
    let pixelBuffer: CVPixelBuffer
    let wrapper: CVMetalTexture
    let texture: any MTLTexture
  }

  private let pool: CVPixelBufferPool
  private let cache: CVMetalTextureCache
  private let canvas: BenchSceneCanvas

  init(device: any MTLDevice, canvas: BenchSceneCanvas) throws {
    self.canvas = canvas
    pool = try Self.pool(canvas)
    cache = try Self.cache(device)
  }

  func make() throws -> Frame {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
    guard status == kCVReturnSuccess, let pixelBuffer else { throw BenchSceneError.pixelBufferUnavailable(status) }

    let wrapper = try texture(of: pixelBuffer)
    guard let texture = CVMetalTextureGetTexture(wrapper) else { throw BenchSceneError.textureUnavailable }

    return Frame(pixelBuffer: pixelBuffer, wrapper: wrapper, texture: texture)
  }

  private func texture(of pixelBuffer: CVPixelBuffer) throws -> CVMetalTexture {
    var wrapper: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      nil, cache, pixelBuffer, nil, BenchSceneRenderer.pixelFormat, canvas.pixelWidth, canvas.pixelHeight, 0, &wrapper)
    guard status == kCVReturnSuccess, let wrapper else { throw BenchSceneError.pixelBufferUnavailable(status) }

    return wrapper
  }

  private static func pool(_ canvas: BenchSceneCanvas) throws -> CVPixelBufferPool {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey: canvas.pixelWidth,
      kCVPixelBufferHeightKey: canvas.pixelHeight,
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw BenchSceneError.pixelBufferUnavailable(status) }

    return pool
  }

  private static func cache(_ device: any MTLDevice) throws -> CVMetalTextureCache {
    var cache: CVMetalTextureCache?
    let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    guard status == kCVReturnSuccess, let cache else { throw BenchSceneError.pixelBufferUnavailable(status) }

    return cache
  }
}

import Metal
import ScreenSharingBench

struct SceneTextureFactory {
  let device: any MTLDevice

  func barcode() throws -> any MTLTexture {
    let layout = BenchBarcodeLayout.standard
    return try make(.bgra8Unorm, width: layout.width, height: layout.height)
  }

  func texture(from bitmap: SceneBitmap) throws -> any MTLTexture {
    let texture = try make(bitmap.format.pixelFormat, width: bitmap.width, height: bitmap.height)
    try bitmap.withBytes { bytes, bytesPerRow in
      texture.replace(
        region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height), mipmapLevel: 0, withBytes: bytes,
        bytesPerRow: bytesPerRow)
    }
    return texture
  }

  func gray(width: Int, height: Int, bytes: [UInt8]) throws -> any MTLTexture {
    try filled(.r8Unorm, width: width, height: height, values: bytes)
  }

  func cells(width: Int, height: Int, values: [UInt32]) throws -> any MTLTexture {
    try filled(.r32Uint, width: width, height: height, values: values)
  }

  private func filled<Value>(
    _ format: MTLPixelFormat, width: Int, height: Int, values: [Value]
  ) throws
    -> any MTLTexture
  {
    precondition(values.count == width * height, "A texture needs one value per pixel")
    let texture = try make(format, width: width, height: height)
    values.withUnsafeBytes {
      texture.replace(
        region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: width * MemoryLayout<Value>.stride)
    }
    return texture
  }

  private func make(_ format: MTLPixelFormat, width: Int, height: Int) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: format, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor) else { throw BenchSceneError.textureUnavailable }

    return texture
  }
}

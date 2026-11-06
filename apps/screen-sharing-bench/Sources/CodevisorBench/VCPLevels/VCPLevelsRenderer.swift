import CoreVideo
import Metal
import ScreenSharing
import ScreenSharingBench

struct VCPLevelsRenderer {
  private let device: any MTLDevice
  private let encoder: ScreenSharingMetalEncoder

  init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw BenchUsageError(message: "Metal is unavailable")
    }

    self.device = device
    let pipelines = try ScreenSharingMetalEncoder.Pipelines(device: device, shader: ScreenSharingMetalView.shader)
    encoder = try ScreenSharingMetalEncoder(device: device, commandQueue: queue, pipelines: pipelines)
  }

  func values(of image: CVPixelBuffer) throws -> [[Int]] {
    let width = CVPixelBufferGetWidth(image)
    let height = CVPixelBufferGetHeight(image)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .renderTarget
    descriptor.storageMode = .shared
    guard let target = device.makeTexture(descriptor: descriptor),
      let textures = encoder.textures(for: ScreenSharingVideoFrame(pixelBuffer: image, timestampNs: 0)),
      let encoded = encoder.encode(textures, into: pass(target), target: target)
    else { throw BenchUsageError(message: "the viewer shader can't draw \(image)") }

    encoded.buffer.commit()
    encoded.buffer.waitUntilCompleted()
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    target.getBytes(
      &pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return withExtendedLifetime(encoded.retained) {
      VCPLevelsRamp.colours.indices.map { index in
        let (x, y) = VCPLevelsRamp.center(of: index)
        let pixel = (y * width + x) * 4
        return [Int(pixels[pixel + 2]), Int(pixels[pixel + 1]), Int(pixels[pixel])]
      }
    }
  }

  private func pass(_ target: any MTLTexture) -> MTLRenderPassDescriptor {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    return pass
  }
}

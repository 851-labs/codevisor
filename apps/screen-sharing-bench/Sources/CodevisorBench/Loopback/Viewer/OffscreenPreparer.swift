import Dispatch
import Metal
import ScreenSharing

final class OffscreenPreparer: ScreenSharingRenderPreparer, @unchecked Sendable {
  private let queue = DispatchQueue(label: "codevisor.bench.offscreen-render", qos: .userInteractive)
  private let device: any MTLDevice
  private let encoder: ScreenSharingMetalEncoder
  private var target: (any MTLTexture)?

  init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else {
      throw ScreenSharingError.unavailable("Metal is unavailable.")
    }

    self.device = device
    let pipelines = try ScreenSharingMetalEncoder.Pipelines(device: device, shader: ScreenSharingMetalView.shader)
    encoder = try ScreenSharingMetalEncoder(device: device, commandQueue: commandQueue, pipelines: pipelines)
  }

  func prepare(
    _ request: ScreenSharingPreparationRequest,
    completion: @escaping @Sendable (ScreenSharingPreparedSubmission?) -> Void
  ) {
    queue.async {
      completion(autoreleasepool { self.render(request) })
    }
  }

  private func render(_ request: ScreenSharingPreparationRequest) -> ScreenSharingPreparedSubmission? {
    guard let textures = encoder.textures(for: request.frame), let target = target(request.geometry) else { return nil }
    guard let encoded = encoder.encode(textures, into: pass(target, geometry: request.geometry), target: target) else {
      return nil
    }

    return ScreenSharingPreparedSubmission(
      submission: OffscreenSubmission(buffer: encoded.buffer), retained: encoded.retained,
      videoSize: ScreenSharingMetalEncoder.videoSize(of: request.frame))
  }

  private func target(_ geometry: ScreenSharingRenderGeometry) -> (any MTLTexture)? {
    let width = Int(geometry.drawableSize.width)
    let height = Int(geometry.drawableSize.height)
    if let target, target.width == width, target.height == height { return target }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .renderTarget
    descriptor.storageMode = .private
    target = device.makeTexture(descriptor: descriptor)
    return target
  }

  private func pass(_ target: any MTLTexture, geometry: ScreenSharingRenderGeometry) -> MTLRenderPassDescriptor {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    let clear = geometry.clearColor
    pass.colorAttachments[0].clearColor = MTLClearColor(red: clear.x, green: clear.y, blue: clear.z, alpha: clear.w)
    return pass
  }
}

import CoreVideo
import Metal

public actor BenchSceneGenerator {
  public nonisolated let setup: BenchSceneSetup
  private let renderer: BenchSceneRenderer
  private let queue: any MTLCommandQueue
  private let frames: ScenePixelBufferPool

  public init(setup: BenchSceneSetup) throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw BenchSceneError.metalUnavailable
    }

    self.setup = setup
    self.queue = queue
    renderer = try BenchSceneRenderer(setup: setup, device: device)
    frames = try ScenePixelBufferPool(device: device, canvas: setup.canvas)
  }

  public func frame(forVersion version: Int) async throws -> BenchSceneFrame {
    let frame = try frames.make()
    guard let commandBuffer = queue.makeCommandBuffer() else { throw BenchSceneError.encoderUnavailable }

    try renderer.encode(version: version, into: frame.texture, commandBuffer: commandBuffer)
    await withCheckedContinuation { finished in
      commandBuffer.addCompletedHandler { _ in finished.resume() }
      commandBuffer.commit()
    }
    withExtendedLifetime(frame.wrapper) {}
    return BenchSceneFrame(version: version, pixelBuffer: frame.pixelBuffer)
  }
}

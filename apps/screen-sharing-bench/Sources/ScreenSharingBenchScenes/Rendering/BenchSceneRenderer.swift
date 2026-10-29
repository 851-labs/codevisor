import Metal
import ScreenSharingBench

public final class BenchSceneRenderer {
  public static let pixelFormat = MTLPixelFormat.bgra8Unorm

  public let setup: BenchSceneSetup
  private let content: any SceneContent
  private let pipeline: any MTLRenderPipelineState
  private let barcodes: MetalRecycler<any MTLTexture>
  private let textures: SceneTextureFactory

  public init(setup: BenchSceneSetup, device: any MTLDevice) throws {
    self.setup = setup
    textures = SceneTextureFactory(device: device)
    content = try SceneContents.make(setup, device: device)
    pipeline = try ScenePipeline.make(device: device, fragmentFunction: content.fragmentFunction)
    barcodes = MetalRecycler()
  }

  public func encode(version: Int, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
    guard BenchBarcode.versions.contains(version) else { throw BenchSceneError.versionOutOfRange(version) }

    let barcode = try barcodeTexture(showing: version, releasedBy: commandBuffer)
    let encoder = try ScenePipeline.encoder(drawingInto: target, commandBuffer: commandBuffer)
    encoder.setRenderPipelineState(pipeline)
    var uniforms = uniforms(forVersion: version)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
    encoder.setFragmentTexture(barcode, index: 0)
    for (index, texture) in content.textures(forVersion: version).enumerated() {
      encoder.setFragmentTexture(texture, index: index + 1)
    }
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
  }

  private func uniforms(forVersion version: Int) -> SceneUniforms {
    var uniforms = content.uniforms(forVersion: version)
    uniforms.version = Int32(version)
    uniforms.extent = SIMD2(Int32(setup.canvas.pixelWidth), Int32(setup.canvas.pixelHeight))
    return uniforms
  }

  private func barcodeTexture(
    showing version: Int, releasedBy commandBuffer: any MTLCommandBuffer
  ) throws
    -> any MTLTexture
  {
    let texture = try barcodes.take(orMake: textures.barcode)
    try BenchBarcode.draw(version, into: texture)
    barcodes.recycle(texture, after: commandBuffer)
    return texture
  }
}

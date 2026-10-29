import Metal

enum ScenePipeline {
  static func make(device: any MTLDevice, fragmentFunction: String) throws -> any MTLRenderPipelineState {
    let options = MTLCompileOptions()
    options.mathMode = .safe
    let library = try device.makeLibrary(source: SceneShaderSource.text, options: options)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: SceneShaderSource.vertexFunction)
    descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
    descriptor.colorAttachments[0].pixelFormat = BenchSceneRenderer.pixelFormat
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  static func encoder(
    drawingInto target: any MTLTexture, commandBuffer: any MTLCommandBuffer
  ) throws
    -> any MTLRenderCommandEncoder
  {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .dontCare
    pass.colorAttachments[0].storeAction = .store
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      throw BenchSceneError.encoderUnavailable
    }

    return encoder
  }
}

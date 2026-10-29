import Metal

protocol SceneContent {
  var fragmentFunction: String { get }

  func uniforms(forVersion version: Int) -> SceneUniforms
  func textures(forVersion version: Int) -> [any MTLTexture]
}

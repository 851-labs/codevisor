struct SceneUniforms {
  var version: Int32 = 0
  var count: Int32 = 0
  var offset: SIMD2<Int32> = .zero
  var size: SIMD2<Int32> = .zero
  var extent: SIMD2<Int32> = .zero
  var seed: UInt32 = 0
  var spare: Int32 = 0
}

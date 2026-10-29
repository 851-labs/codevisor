import Metal
import ScreenSharingBench

struct VideoContent: SceneContent {
  private static let drift = (x: 7, y: 3)

  let fragmentFunction = "video"
  private let noise: any MTLTexture

  init(_ setup: BenchSceneSetup, textures: SceneTextureFactory) throws {
    let canvas = setup.canvas
    let bytes = Self.noise(count: canvas.pixelWidth * canvas.pixelHeight, seed: setup.seed)
    noise = try textures.gray(width: canvas.pixelWidth, height: canvas.pixelHeight, bytes: bytes)
  }

  func uniforms(forVersion tick: Int) -> SceneUniforms {
    let x = tick % noise.width * Self.drift.x % noise.width
    let y = tick % noise.height * Self.drift.y % noise.height
    return SceneUniforms(offset: SIMD2(Int32(x), Int32(y)))
  }

  func textures(forVersion version: Int) -> [any MTLTexture] {
    [noise]
  }

  private static func noise(count: Int, seed: UInt64) -> [UInt8] {
    var random = SplitMix64(seed: seed ^ SceneStreams.videoNoise &* 0x9E37_79B9_7F4A_7C15)
    var bytes = [UInt8](repeating: 0, count: count)
    bytes.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < count {
        var word = random.next()
        let chunk = min(MemoryLayout<UInt64>.size, count - offset)
        withUnsafeBytes(of: &word) {
          buffer.baseAddress!.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: chunk)
        }
        offset += chunk
      }
    }
    return bytes
  }
}

import Metal
import ScreenSharingBenchScenes
import Synchronization

final class PlayerHashRecorder: Sendable {
  private let hasher: BenchTextureHasher
  private let recorded = Mutex<[SceneHashLog.Entry]>([])
  private let skipped = Mutex(0)

  init(device: any MTLDevice, canvas: BenchSceneCanvas) {
    hasher = BenchTextureHasher(device: device, canvas: canvas)
  }

  var entries: [SceneHashLog.Entry] {
    recorded.withLock { $0 }
  }

  var skippedVersions: Int {
    skipped.withLock { $0 }
  }

  func capture(version: Int, from texture: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
    let hashing = try hasher.hash(texture, commandBuffer: commandBuffer) { hash in
      self.recorded.withLock { $0.append(SceneHashLog.Entry(version: version, sha256: hash)) }
    }
    if !hashing { skipped.withLock { $0 += 1 } }
  }
}

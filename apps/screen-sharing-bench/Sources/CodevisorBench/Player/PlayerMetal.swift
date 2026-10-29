import Metal
import ScreenSharingBenchScenes

enum PlayerMetal {
  static func device() throws -> any MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else { throw BenchSceneError.metalUnavailable }

    return device
  }
}

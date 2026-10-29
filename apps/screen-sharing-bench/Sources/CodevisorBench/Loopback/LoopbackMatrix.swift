import ScreenSharingBench
import ScreenSharingBenchScenes

enum LoopbackMatrix {
  static let defaultScenes: [BenchScene] = [.idleCursor, .typing, .scroll, .windowDrag, .video, .testCards]

  static func scenes(_ list: String?) throws -> [BenchScene] {
    guard let list else { return defaultScenes }

    return try names(list).map { name in
      guard let scene = BenchScene(rawValue: name), defaultScenes.contains(scene) else {
        let choices = defaultScenes.map(\.rawValue).joined(separator: ", ")
        throw BenchUsageError(message: "--scenes takes \(choices), not \(name)")
      }
      return scene
    }
  }

  static func networks(_ list: String?) throws -> [BenchNetworkConditions] {
    guard let list else { return BenchNetworkConditions.matrix }

    return try names(list).map { id in
      guard let conditions = BenchNetworkConditions.matrix.first(where: { $0.id == id }) else {
        throw BenchUsageError(message: "--networks takes N0 to N7, not \(id)")
      }
      return conditions
    }
  }

  static func resolution(_ resolution: BenchSceneResolution) throws -> BenchSceneResolution {
    guard resolution == .r1 else {
      throw BenchUsageError(message: "loopback runs at R1 only until R2 and R3 land (T9)")
    }

    return resolution
  }

  private static func names(_ list: String) -> [String] {
    list.split(separator: ",").map { String($0) }
  }
}

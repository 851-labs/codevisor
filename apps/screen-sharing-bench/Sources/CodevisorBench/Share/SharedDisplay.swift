import CoreGraphics
import ScreenSharingBenchScenes

@MainActor
struct SharedDisplay {
  let id: CGDirectDisplayID
  private let virtualDisplay: PlayerVirtualDisplay?

  static func make(_ resolution: BenchSceneResolution?) async throws -> SharedDisplay {
    guard let resolution else { return SharedDisplay(id: CGMainDisplayID(), virtualDisplay: nil) }

    let display = try PlayerVirtualDisplay(resolution)
    _ = try await display.screen()
    return SharedDisplay(id: display.displayID, virtualDisplay: display)
  }
}

import AppKit
import ScreenSharingBenchScenes

@MainActor
struct ViewerDisplay {
  let screen: NSScreen
  let id: CGDirectDisplayID
  private let virtualDisplay: PlayerVirtualDisplay?

  static func make(_ resolution: BenchSceneResolution?) async throws -> ViewerDisplay {
    guard let resolution else { return try main() }

    let display = try PlayerVirtualDisplay(resolution)
    return ViewerDisplay(screen: try await display.screen(), id: display.displayID, virtualDisplay: display)
  }

  var bounds: CGRect {
    CGDisplayBounds(id)
  }

  var readyDetail: String {
    "display \(id)"
  }

  private static func main() throws -> ViewerDisplay {
    guard let screen = NSScreen.main else { throw BenchUsageError(message: "this Mac has no screen") }

    return ViewerDisplay(screen: screen, id: CGMainDisplayID(), virtualDisplay: nil)
  }
}

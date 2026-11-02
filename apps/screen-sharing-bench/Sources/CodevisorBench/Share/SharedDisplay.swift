import AppKit
import ScreenSharingBenchScenes

@MainActor
struct SharedDisplay {
  private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

  let id: CGDirectDisplayID
  private let virtualDisplay: PlayerVirtualDisplay?

  static func make(_ resolution: BenchSceneResolution?) async throws -> SharedDisplay {
    guard let resolution else { return SharedDisplay(id: CGMainDisplayID(), virtualDisplay: nil) }

    let display = try PlayerVirtualDisplay(resolution)
    _ = try await display.screen()
    return SharedDisplay(id: display.displayID, virtualDisplay: display)
  }

  var bounds: CGRect {
    CGDisplayBounds(id)
  }

  var readyDetail: String {
    "display \(id)"
  }

  func screen() throws -> NSScreen {
    guard
      let screen = NSScreen.screens.first(where: {
        $0.deviceDescription[Self.screenNumberKey] as? CGDirectDisplayID == id
      })
    else { throw BenchUsageError(message: "no screen for display \(id)") }

    return screen
  }
}

import AppKit
import ScreenSharingBenchScenes

@MainActor
struct PlayerScreenTarget {
  let screen: NSScreen
  let canvas: BenchSceneCanvas
  let resolution: SceneResolutionChoice
  let display: PlayerDisplayChoice
  private let virtualDisplay: PlayerVirtualDisplay?

  static func make(display: PlayerDisplayChoice, resolution: SceneResolutionChoice) async throws -> PlayerScreenTarget {
    switch display {
    case .main: try main(resolution)
    case .virtual: try await virtual(resolution)
    }
  }

  var refreshHz: Int {
    screen.maximumFramesPerSecond
  }

  private static func main(_ resolution: SceneResolutionChoice) throws -> PlayerScreenTarget {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { throw PlayerError.noScreen }

    let target = PlayerScreenTarget(
      screen: screen, canvas: canvas(of: screen), resolution: resolution, display: .main, virtualDisplay: nil)
    try target.requireMatch()
    return target
  }

  private static func virtual(_ resolution: SceneResolutionChoice) async throws -> PlayerScreenTarget {
    guard let fixed = resolution.fixed else {
      throw BenchUsageError(message: "--display virtual needs --resolution R1, R2 or R3")
    }

    let display = try PlayerVirtualDisplay(fixed)
    let screen = try await display.screen()
    let target = PlayerScreenTarget(
      screen: screen, canvas: canvas(of: screen), resolution: resolution, display: .virtual, virtualDisplay: display)
    try target.requireMatch()
    return target
  }

  private func requireMatch() throws {
    guard let fixed = resolution.fixed, canvas != BenchSceneCanvas(fixed) else { return }

    throw PlayerError.displayMismatch(
      "The \(display.rawValue) display is \(canvas.pointWidth)×\(canvas.pointHeight) pt at \(canvas.scale)x, not "
        + "\(fixed.rawValue). Use --display virtual or --resolution native.")
  }

  private static func canvas(of screen: NSScreen) -> BenchSceneCanvas {
    let scale = screen.backingScaleFactor
    return BenchSceneCanvas(
      pixelWidth: Int(screen.frame.width * scale), pixelHeight: Int(screen.frame.height * scale), scale: Int(scale))
  }
}

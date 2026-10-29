import AppKit
import ApplicationServices

struct AppleHPCommand: BenchCommand {
  static let name = "apple-hp"
  static let summary = "Connect Screen Sharing.app to the host (saved password, High Performance) full screen"
  static let usage = "[--host <bonjour name>] [--duration <seconds>] \(BenchSignalFiles.usage)"

  private static let defaultHost = "tamales-Mac-Mini.local"
  private static let durations = 1...7200
  private static let connectTimeout = Duration.seconds(30)
  private static let fullScreenTimeout = Duration.seconds(10)
  private static let quitTimeout = Duration.seconds(5)

  let presentsWindows = false
  private let host: String
  private let duration: Duration
  private let signals: BenchSignalFiles

  init(options: BenchOptions) throws {
    host = try options.string("host", default: Self.defaultHost)
    duration = .seconds(try options.integer("duration", default: 120, in: Self.durations))
    signals = try BenchSignalFiles(options: options)
  }

  func run() async throws {
    guard AXIsProcessTrusted() else { throw AppleHPError.notTrusted }
    guard let screen = NSScreen.main?.frame else { throw BenchUsageError(message: "this Mac has no screen") }

    let deadline = ContinuousClock.now + duration
    let app = try await ScreenSharingApp.connect(to: host)
    do {
      let session = try await app.sessionWindow(showing: host, timeout: Self.connectTimeout)

      let window = session.window
      try await app.makeFullScreen(window, screen: screen, timeout: Self.fullScreenTimeout)
      PointerParking.parkAwayFromTheMenuBar()
      try signals.markReady("full screen")
      let focusLosses = await FrontmostKeeper.hold(app.application, until: deadline, signals: signals)
      let result = AppleHPResult(
        host: host, choseHighPerformance: session.choseHighPerformance == true, focusLosses: focusLosses,
        sessionOnScreen: WindowSharingStates.coversScreen(app.application.processIdentifier, screen: screen),
        window: WindowDescription(window),
        checkedMenuItems: app.checkedMenuItems,
        windowSharingStates: WindowSharingStates.of(app.application.processIdentifier))
      await app.quit(timeout: Self.quitTimeout)
      try BenchOutput.print(result)
    } catch {
      await app.quit(timeout: Self.quitTimeout)
      throw error
    }
  }
}

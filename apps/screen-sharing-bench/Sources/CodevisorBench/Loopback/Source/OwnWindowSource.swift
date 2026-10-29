import ScreenCaptureKit
import ScreenSharing
import ScreenSharingBench
import ScreenSharingBenchScenes
import ScreenSharingWebRTC

@MainActor
final class OwnWindowSource: LoopbackSource {
  private static let windowLookups = 20
  private static let windowLookupInterval = Duration.milliseconds(50)

  private let target: PlayerScreenTarget
  private let window: PlayerWindow
  private let loop: PlayerDisplayLoop
  private let versions: CapturedVersions
  private let metrics: ScreenSharingMetrics
  private let capture = ScreenSharingCapture(pixelFormat: ScreenSharingProductProfile.codec.capturePixelFormat)
  private var configuration: ScreenSharingVideoConfiguration?
  private var capturing = false

  init(
    setup: BenchSceneSetup, target: PlayerScreenTarget, sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics
  )
    throws
  {
    try PlayerConsoleSession.requireUnlocked()
    let device = try PlayerMetal.device()
    self.target = target
    window = PlayerWindow(screen: target.screen, device: device, readable: false)
    loop = try PlayerDisplayLoop(
      renderer: BenchSceneRenderer(setup: setup, device: device), device: device,
      versions: PlayerVersionSource(timeline: setup.scene.timeline), hashes: nil)
    versions = CapturedVersions(forwardingTo: sink, canvasWidth: setup.canvas.pixelWidth)
    self.metrics = metrics
  }

  var produced: [BenchVersionEvent] { versions.produced }

  func run(for duration: Duration) async throws {
    PlayerPresentation.show(window)
    defer { PlayerPresentation.hide(window) }

    loop.start(layer: window.metalLayer)
    do {
      try await startCapture()
      try await Task.sleep(for: duration)
    } catch {
      await stopCapture()
      _ = try? await loop.stop()
      throw error
    }
    await stopCapture()
    _ = try await loop.stop()
  }

  func adapt(to configuration: ScreenSharingVideoConfiguration) async throws {
    self.configuration = configuration
    guard capturing else { return }

    try await capture.update(configuration: configuration)
  }

  private func startCapture() async throws {
    guard let configuration else { throw ScreenSharingError.invalid("The capture has no configuration.") }

    let filter = SCContentFilter(desktopIndependentWindow: try await ownWindow())
    try await capture.start(filter: filter, configuration: configuration, sink: versions, metrics: metrics)
    capturing = true
  }

  private func stopCapture() async {
    guard capturing else { return }

    try? await capture.stop()
    capturing = false
  }

  private func ownWindow() async throws -> SCWindow {
    for _ in 0..<Self.windowLookups {
      let windows = try await SCShareableContent.currentProcess.windows
      if let shared = windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) { return shared }
      try await Task.sleep(for: Self.windowLookupInterval)
    }
    throw ScreenSharingError.unavailable("ScreenCaptureKit doesn't list the scene window.")
  }
}

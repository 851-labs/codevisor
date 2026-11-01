import CoreGraphics
import CoreVideo
import ScreenSharing
import ScreenSharingBench
import ScreenSharingBenchScenes

@MainActor
enum LoopbackEnds {
  private static let settle = Duration.milliseconds(250)
  private static let longestDrain = Duration.seconds(5)
  private static let drainPoll = Duration.milliseconds(50)

  static func source(
    _ scene: BenchScene, settings: LoopbackSettings, sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics,
    pixelFormat: OSType
  ) async throws -> any LoopbackSource {
    let setup = BenchSceneSetup(scene: scene, seed: settings.seed, canvas: settings.canvas)
    switch settings.source {
    case .synthetic:
      return try SyntheticSource(setup: setup, sink: sink)
    case .ownWindow:
      let resolution = SceneResolutionChoice(rawValue: settings.resolution.rawValue) ?? .native
      let target = try await PlayerScreenTarget.make(display: settings.display, displayID: nil, resolution: resolution)
      return try OwnWindowSource(setup: setup, target: target, sink: sink, metrics: metrics, pixelFormat: pixelFormat)
    }
  }

  static func viewer(
    settings: LoopbackSettings, mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics
  ) throws -> any LoopbackViewer {
    switch settings.endpoint {
    case .committed:
      let size = CGSize(width: settings.canvas.pixelWidth, height: settings.canvas.pixelHeight)
      return try OffscreenViewer(mailbox: mailbox, metrics: metrics, drawableSize: size)
    case .onGlass:
      return try OnscreenViewer(mailbox: mailbox, metrics: metrics)
    }
  }

  static func drain(_ relay: LoopbackRelay) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + longestDrain
    while !relay.isIdle, clock.now < deadline { try await Task.sleep(for: drainPoll) }
    try await Task.sleep(for: settle)
  }
}

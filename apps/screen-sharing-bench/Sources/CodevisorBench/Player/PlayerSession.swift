import AppKit
import Metal
import ScreenSharingBenchScenes

@MainActor
struct PlayerSession {
  private let configuration: PlayerConfiguration

  init(_ configuration: PlayerConfiguration) {
    self.configuration = configuration
  }

  func run() async throws -> PlayerReport {
    try PlayerConsoleSession.requireUnlocked()
    let target = try await PlayerScreenTarget.make(
      display: configuration.display, displayID: configuration.displayID, resolution: configuration.resolution)

    let setup = BenchSceneSetup(
      scene: configuration.scene, seed: configuration.seed, canvas: target.canvas,
      inputRegion: configuration.inputRegion)
    let device = try PlayerMetal.device()
    let hashes = configuration.hashLog.map { _ in PlayerHashRecorder(device: device, canvas: setup.canvas) }
    let window = PlayerWindow(screen: target.screen, device: device, readable: hashes != nil)
    let versions = PlayerVersionSource(timeline: configuration.scene.timeline)
    window.onInput = versions.recordInput
    let loop = try PlayerDisplayLoop(
      renderer: BenchSceneRenderer(setup: setup, device: device), device: device, versions: versions, hashes: hashes)

    let measurement = try await play(window: window, loop: loop)
    try writeHashes(hashes, setup: setup)
    return withExtendedLifetime(target) {
      PlayerReport(
        configuration, target: target, measurement: measurement, inputEvents: versions.inputEvents,
        unhashedVersions: hashes?.skippedVersions)
    }
  }

  private func play(window: PlayerWindow, loop: PlayerDisplayLoop) async throws -> PlayerMeasurement {
    PlayerPresentation.show(window)
    defer { PlayerPresentation.hide(window) }

    let selfInput = PlayerSelfInput.start(hz: configuration.selfInputHz, window: window)
    defer { selfInput?.cancel() }

    loop.start(layer: window.metalLayer)
    try await Task.sleep(for: .seconds(configuration.duration))
    return try await loop.stop()
  }

  private func writeHashes(_ hashes: PlayerHashRecorder?, setup: BenchSceneSetup) throws {
    guard let hashes, let path = configuration.hashLog else { return }

    try SceneHashLog(setup: setup, entries: hashes.entries).write(to: path)
  }
}

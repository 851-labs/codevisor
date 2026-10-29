import CoreGraphics
import ScreenSharing
import ScreenSharingBench
import ScreenSharingBenchScenes
import ScreenSharingWebRTC

@MainActor
struct LoopbackCell {
  private static let settle = Duration.milliseconds(250)
  private static let longestDrain = Duration.seconds(5)
  private static let drainPoll = Duration.milliseconds(50)

  let scene: BenchScene
  let conditions: BenchNetworkConditions
  let settings: LoopbackSettings
  let repetition: Int

  func run() async throws -> LoopbackOutcome {
    let clockOffsetNs = BenchMachClock.continuousMinusAbsoluteNs()
    let relayOriginNs = BenchMachClock.nowNs()
    let relay = try LoopbackRelay(conditions: conditions, seed: settings.seed, originNs: relayOriginNs)
    defer { relay.close() }

    let peers = try await LoopbackPeers(configuration: configuration)
    let recording: LoopbackRecording
    do {
      recording = try await record(peers, through: relay)
    } catch {
      await peers.close()
      throw error
    }
    await peers.close()

    let measured = LoopbackMeasurement(
      scene: scene, conditions: conditions, settings: settings, repetition: repetition, clockOffsetNs: clockOffsetNs,
      relayOriginNs: relayOriginNs)
    return measured.outcome(recording, relay: relay)
  }

  private var configuration: ScreenSharingVideoConfiguration {
    get throws {
      try ScreenSharingProductProfile.captureConfiguration(
        width: settings.canvas.pixelWidth, height: settings.canvas.pixelHeight)
    }
  }

  private func record(_ peers: LoopbackPeers, through relay: LoopbackRelay) async throws -> LoopbackRecording {
    try await peers.connect(through: relay)
    let source = try await makeSource(peers)
    try await source.adapt(to: configuration)
    let instruments = LoopbackInstruments(
      peers: peers, viewer: try makeViewer(peers), canvasWidth: settings.canvas.pixelWidth)

    instruments.start(source: source, configuration: try configuration, warmUp: .seconds(settings.warmUpSeconds))
    let startNs = ScreenSharingMetrics.nowNs
    do {
      try await source.run(for: .seconds(settings.durationSeconds))
      try await drain(relay)
    } catch {
      _ = instruments.stop()
      throw error
    }
    return LoopbackRecording(
      startNs: startNs, produced: await source.produced, readings: instruments.stop(),
      hostCounters: peers.hostMetrics.counters(), viewerCounters: peers.viewerMetrics.counters(),
      codecFailure: peers.hostMetrics.label("encoderError") ?? peers.viewerMetrics.label("decoderError"),
      jitterDrops: peers.receiver.mailbox.droppedFrames)
  }

  private func drain(_ relay: LoopbackRelay) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + Self.longestDrain
    while !relay.isIdle, clock.now < deadline { try await Task.sleep(for: Self.drainPoll) }
    try await Task.sleep(for: Self.settle)
  }

  private func makeSource(_ peers: LoopbackPeers) async throws -> any LoopbackSource {
    let setup = BenchSceneSetup(scene: scene, seed: settings.seed, canvas: settings.canvas)
    switch settings.source {
    case .synthetic:
      return try SyntheticSource(setup: setup, sink: peers.sender.frameSender)
    case .ownWindow:
      let resolution = SceneResolutionChoice(rawValue: settings.resolution.rawValue) ?? .native
      let target = try await PlayerScreenTarget.make(display: settings.display, displayID: nil, resolution: resolution)
      return try OwnWindowSource(
        setup: setup, target: target, sink: peers.sender.frameSender, metrics: peers.hostMetrics)
    }
  }

  private func makeViewer(_ peers: LoopbackPeers) throws -> any LoopbackViewer {
    let mailbox = peers.receiver.mailbox
    switch settings.endpoint {
    case .committed:
      let size = CGSize(width: settings.canvas.pixelWidth, height: settings.canvas.pixelHeight)
      return try OffscreenViewer(mailbox: mailbox, metrics: peers.viewerMetrics, drawableSize: size)
    case .onGlass:
      return try OnscreenViewer(mailbox: mailbox, metrics: peers.viewerMetrics)
    }
  }
}

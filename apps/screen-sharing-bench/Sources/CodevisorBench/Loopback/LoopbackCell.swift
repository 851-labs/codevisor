import ScreenSharing
import ScreenSharingBench
import ScreenSharingBenchScenes
import ScreenSharingWebRTC

@MainActor
struct LoopbackCell {
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
    let source = try await LoopbackEnds.source(
      scene, settings: settings, sink: peers.sender.frameSender, metrics: peers.hostMetrics,
      pixelFormat: ScreenSharingProductProfile.codec.capturePixelFormat)
    try await source.adapt(to: configuration)
    let viewer = try LoopbackEnds.viewer(
      settings: settings, mailbox: peers.receiver.mailbox, metrics: peers.viewerMetrics)
    let instruments = LoopbackInstruments(peers: peers, viewer: viewer, canvasWidth: settings.canvas.pixelWidth)

    instruments.start(source: source, configuration: try configuration, warmUp: .seconds(settings.warmUpSeconds))
    let startNs = ScreenSharingMetrics.nowNs
    do {
      try await source.run(for: .seconds(settings.durationSeconds))
      try await LoopbackEnds.drain(relay)
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
}

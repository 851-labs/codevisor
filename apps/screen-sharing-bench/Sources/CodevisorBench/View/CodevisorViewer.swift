import ScreenSharing
import ScreenSharingWebRTC

@MainActor
final class CodevisorViewer {
  private static let connectRetry = Duration.milliseconds(250)
  private static let statisticsInterval = Duration.seconds(1)
  private static let firstFrameTimeout = Duration.seconds(20)
  private static let controlTimeout = Duration.seconds(15)

  private let receiver: ScreenSharingReceiver
  private let surface: ScreenSharingVideoSurface
  private let firstFrame = FirstPresentation()
  private var control: BenchViewerControl?

  static func run(
    in window: ViewerWindow, host: String, port: UInt16, takesControl: Bool, until deadline: ContinuousClock.Instant,
    signals: BenchSignalFiles
  ) async throws -> CodevisorViewResult {
    let viewer = try await CodevisorViewer(in: window)
    do {
      let connection = try await viewer.connect(host: host, port: port, until: deadline)
      try await viewer.firstFrame.wait(timeout: firstFrameTimeout)
      if takesControl { try await viewer.takeControl() }
      try signals.markReady("presenting")
      let polling = Task { await viewer.pollStatistics() }
      await BenchSession.hold(connection, until: deadline, signals: signals)
      polling.cancel()
      return await viewer.finish(host: host)
    } catch {
      _ = await viewer.finish(host: host)
      throw error
    }
  }

  private func takeControl() async throws {
    control = try await BenchViewerControl.acquire(
      over: receiver.controlChannel, surface: surface, timeout: Self.controlTimeout)
  }

  private init(in window: ViewerWindow) async throws {
    receiver = try await ScreenSharingReceiver(configuration: .init(), metrics: ScreenSharingMetrics())
    receiver.frames.retainsLatest = true
    surface = try ScreenSharingVideoSurface(mailbox: receiver.mailbox, metrics: receiver.metrics)
    surface.onPresented = { [firstFrame] in firstFrame.record() }
    window.show(surface)
  }

  private func connect(
    host: String, port: UInt16, until deadline: ContinuousClock.Instant
  ) async throws
    -> SignalingConnection
  {
    let offer = try await receiver.makeDescription(offer: true)
    let connection = try await SignalingSocket.connect(
      host: host, port: port, until: deadline, retry: Self.connectRetry)
    try connection.send(SignalingMessage(sdp: offer.sdp))
    let answer = try await Self.receive(connection)
    try await receiver.accept(ScreenSharingDescription(kind: "answer", sdp: answer.sdp))
    return connection
  }

  private func pollStatistics() async {
    while !Task.isCancelled {
      receiver.metrics.timeline.observeTransport(await receiver.statistics())
      try? await Task.sleep(for: Self.statisticsInterval)
    }
  }

  private func finish(host: String) async -> CodevisorViewResult {
    control?.stop()
    let statistics = await receiver.statistics()
    let result = CodevisorViewResult(
      host: host, firstPresentedNs: firstFrame.presentedNs, metrics: receiver.metrics,
      droppedFrames: receiver.mailbox.droppedFrames, statistics: statistics, control: control?.summary)
    receiver.close()
    _ = await receiver.awaitClosed()
    return result
  }

  @concurrent
  private static func receive(_ connection: SignalingConnection) async throws -> SignalingMessage {
    try connection.receive(SignalingMessage.self)
  }
}

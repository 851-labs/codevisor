#if os(macOS)
  import Testing

  @testable import ScreenSharing
  @testable import ScreenSharingV2

  @Suite(.timeLimit(.minutes(1)))
  struct ScreenSharingV2CaptureRestartTests {
    private static let tiled = ScreenSharingV2TileLayout(width: 640, height: 360, count: 4)

    private let encoder = RecordingTileEncoder(layout: Self.tiled)

    private func startedHost() -> ScreenSharingV2Host {
      let host = ScreenSharingV2Host(
        transport: LoopbackMediaTransport(), encoder: encoder, metrics: ScreenSharingMetrics(),
        initialBitrate: ScreenSharingV2Profile.bitrateCeiling, scheduler: ManualScheduler())
      host.start()
      return host
    }

    @Test func aRestartedCaptureSendsEveryTileThatChangedWhileNoFramesCame() async throws {
      let host = startedHost()
      let beforeTheRestart = TestCaptureRun(into: host)
      let afterTheRestart = TestCaptureRun(into: host)

      try beforeTheRestart.deliverFirstFrame(shades: [10, 20, 30, 40], timestampNs: 1_000)
      await encoder.encodes.cancellableWait(for: 1)
      encoder.emitTiles(of: encoder.requests[0])
      try afterTheRestart.deliverFirstFrame(shades: [10, 20, 99, 40], timestampNs: 2_000)
      host.stop()

      #expect(encoder.requests.map(\.update.tiles) == [[0, 1, 2, 3], [1, 2]])
    }
  }
#endif

import CoreGraphics
import CodevisorTestSupport
import Synchronization
import Testing
import VideoToolbox

@testable import ScreenSharing
@testable import ScreenSharingV2

extension HardwareCodecTests {
  @Suite(.timeLimit(.minutes(1)))
  struct ScreenSharingV2EngineTests {
    private static let framesBeforeAnAcknowledgement = 30

    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func aDroppedFrameIsRepairedByALongTermReferenceRefreshWithoutAKeyframe() async throws {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      let metrics = ScreenSharingMetrics()
      let host = try await Self.host(transport: hostSide, metrics: metrics, tiles: 1)
      let viewer = ScreenSharingV2Viewer(transport: viewerSide, metrics: ScreenSharingMetrics())
      let decoded = DecodedFrames(viewer.frames)
      host.start()
      viewer.start()
      defer { host.stop(); viewer.stop() }

      let delivered = try await streamUntilAReferenceIsAcknowledged(host, decoded: decoded, viewer: viewerSide)
      hostSide.dropNextFrame()
      host.push(try TestPixels.frame(shade: 250, timestampNs: 99_000))
      await hostSide.dropped.cancellableWait()
      viewerSide.emit(.frameSkipped(stream: 0, frame: UInt32(delivered)))
      hostSide.emit(.frameLost(stream: 0, frame: UInt32(delivered)))
      await decoded.arrivals.cancellableWait(for: delivered + 1)

      #expect(decoded.sourceTimestamps.last == 99_000)
      #expect(hostSide.sent.last?.refresh == .longTermReference)
      #expect(hostSide.sent.last?.isKeyFrame == false)
      #expect(metrics.counter("encodedKeyFrames") == 1)
    }

    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func aFrameTheViewerCannotDecodeIsRepairedThroughARefreshRequestWithoutAKeyframe() async throws {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      let metrics = ScreenSharingMetrics()
      let host = try await Self.host(transport: hostSide, metrics: metrics, tiles: 1)
      let viewer = ScreenSharingV2Viewer(transport: viewerSide, metrics: ScreenSharingMetrics())
      let decoded = DecodedFrames(viewer.frames)
      host.start()
      viewer.start()
      defer { host.stop(); viewer.stop() }

      let delivered = try await streamUntilAReferenceIsAcknowledged(host, decoded: decoded, viewer: viewerSide)
      hostSide.corruptNextFrame()
      host.push(try TestPixels.frame(shade: 250, timestampNs: 99_000))
      await decoded.arrivals.cancellableWait(for: delivered + 1)

      #expect(decoded.sourceTimestamps.last == 99_000)
      #expect(viewerSide.requestedRefreshes.map(\.keyframe) == [false])
      #expect(hostSide.sent.last?.refresh == .longTermReference)
      #expect(metrics.counter("encodedKeyFrames") == 1)
    }

    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func tilesAreComposedIntoOneSeamlessPictureAndOnlyDirtyTilesAreSent() async throws {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      let host = try await Self.host(transport: hostSide, metrics: ScreenSharingMetrics(), tiles: 4)
      let viewer = ScreenSharingV2Viewer(transport: viewerSide, metrics: ScreenSharingMetrics())
      let decoded = DecodedFrames(viewer.frames)
      host.start()
      viewer.start()
      defer { host.stop(); viewer.stop() }

      host.push(try TestPixels.frame(shades: [40, 90, 140, 190], timestampNs: 1_000))
      await decoded.arrivals.cancellableWait(for: 1)
      host.push(
        try TestPixels.frame(
          shades: [40, 90, 230, 190], timestampNs: 2_000, dirtyRects: [CGRect(x: 0, y: 180, width: 640, height: 90)]))
      await decoded.arrivals.cancellableWait(for: 2)
      await hostSide.sends.cancellableWait(for: 6)

      #expect(Set(hostSide.sent.prefix(4).map(\.tile)) == [0, 1, 2, 3])
      #expect(hostSide.sent.dropFirst(4).map(\.tile).sorted() == [1, 2])
      let pictures = decoded.frames.map(\.pixelBuffer)
      try #require(pictures.map { CVPixelBufferGetHeight($0) } == [360, 360])
      #expect(Self.tileShades(pictures[0]).allSatisfy { abs($0.0 - $0.1) <= 3 }, "\(Self.tileShades(pictures[0]))")
      #expect(abs(Int(Self.lumaRow(pictures[0], row: 89)) - 40) <= 3)
      #expect(abs(Int(Self.lumaRow(pictures[0], row: 90)) - 90) <= 3)
      let second = Self.tileShades(pictures[1], expected: [40, 90, 230, 190])
      #expect(second.allSatisfy { abs($0.0 - $0.1) <= 3 }, "\(second)")
    }

    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func withTilesTheViewerHandsOverEachDecodedTileInsteadOfComposingThePicture() async throws {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      let host = try await Self.host(transport: hostSide, metrics: ScreenSharingMetrics(), tiles: 4)
      let metrics = ScreenSharingMetrics()
      let viewer = ScreenSharingV2Viewer(transport: viewerSide, metrics: metrics, presentsTiles: true)
      let decoded = DecodedFrames(viewer.frames)
      host.start()
      viewer.start()
      defer { host.stop(); viewer.stop() }

      host.push(try TestPixels.frame(shades: [40, 90, 140, 190], timestampNs: 1_000))
      await decoded.arrivals.cancellableWait(for: 1)
      host.push(
        try TestPixels.frame(
          shades: [40, 90, 230, 190], timestampNs: 2_000, dirtyRects: [CGRect(x: 0, y: 180, width: 640, height: 90)]))
      await decoded.arrivals.cancellableWait(for: 2)

      let frames = decoded.frames
      #expect(frames.allSatisfy { $0.tiles?.count == 4 && $0.size == CGSize(width: 640, height: 360) })
      #expect(frames.map { Self.shade($0, row: 225) }.map { abs($0 - 140) <= 3 } == [true, false])
      #expect(abs(Self.shade(try #require(frames.last), row: 225) - 230) <= 3)
      #expect(abs(Self.shade(try #require(frames.last), row: 45) - 40) <= 3)
      #expect(metrics.snapshot().timings["compose"] == nil)
    }

    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func anUpdateSharesTheBitrateBetweenItsTilesOnceEachTileEncodedItsOpeningFrame() async throws {
      try await HardwareEncoderBudget.require(videoToolboxTiles: 4)
      let configuration = try ScreenSharingVideoConfiguration(width: 640, height: 360, bitrate: 40_000_000)
      let encoder = try ScreenSharingVideoToolboxTileEncoder(
        configuration: configuration, layout: ScreenSharingV2TileLayout(width: 640, height: 360, count: 4),
        metrics: ScreenSharingMetrics())
      defer { encoder.stop() }
      let answered = TestSignal()
      encoder.onOutput { _ in answered.signal() }
      let pixels = try TestPixels.frame(shade: 80, timestampNs: 1).pixelBuffer
      let opening = ScreenSharingV2Profile.openingBitrate / 4

      try encoder.encode(
        ScreenSharingTileEncodeRequest(
          pixelBuffer: pixels, sourceTimestampNs: 1, capturedNs: 1,
          update: ScreenSharingTileUpdate(id: 1, tiles: [0, 1, 2, 3])))
      #expect(encoder.sessions.map(\.bitrate) == Array(repeating: opening, count: 4))
      await answered.cancellableWait(for: 4)

      try encoder.encode(
        ScreenSharingTileEncodeRequest(
          pixelBuffer: pixels, sourceTimestampNs: 2, capturedNs: 2,
          update: ScreenSharingTileUpdate(id: 2, tiles: [0, 1, 2, 3])))
      #expect(encoder.sessions.map(\.bitrate) == Array(repeating: 10_000_000, count: 4))

      try encoder.encode(
        ScreenSharingTileEncodeRequest(
          pixelBuffer: pixels, sourceTimestampNs: 3, capturedNs: 3, update: ScreenSharingTileUpdate(id: 3, tiles: [2])))
      #expect(encoder.sessions.map(\.bitrate) == [10_000_000, 10_000_000, 40_000_000, 10_000_000])
    }

    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func aSuspendedVideoToolboxEncoderReopensItsSessionOnTheNextEncode() async throws {
      try await HardwareEncoderBudget.require(videoToolboxTiles: 1)
      let configuration = try ScreenSharingVideoConfiguration(width: 640, height: 360, bitrate: 10_000_000)
      let metrics = ScreenSharingMetrics()
      let encoder = try ScreenSharingVideoToolboxTileEncoder(
        configuration: configuration, layout: ScreenSharingV2TileLayout(width: 640, height: 360, count: 1),
        metrics: metrics)
      defer { encoder.stop() }
      let tiles = Mutex<[ScreenSharingEncodedTile]>([])
      let answered = TestSignal()
      encoder.onOutput { output in
        if case .tile(let tile) = output { tiles.withLock { $0.append(tile) } }
        answered.signal()
      }
      let pixels = try TestPixels.frame(shade: 80, timestampNs: 1).pixelBuffer
      let request = { (id: UInt32) in
        ScreenSharingTileEncodeRequest(
          pixelBuffer: pixels, sourceTimestampNs: Int64(id), capturedNs: Int64(id),
          update: ScreenSharingTileUpdate(id: id, tiles: [0]))
      }

      try encoder.encode(request(1))
      await answered.cancellableWait(for: 1)
      encoder.suspend()
      try encoder.encode(request(2))
      await answered.cancellableWait(for: 2)

      #expect(metrics.counter("encoderSessionReopens") == 1)
      #expect(tiles.withLock { $0.map(\.update.id) } == [1, 2])
    }

    private static func host(
      transport: LoopbackMediaTransport, metrics: ScreenSharingMetrics, tiles: Int
    ) async throws -> ScreenSharingV2Host {
      try await HardwareEncoderBudget.require(videoToolboxTiles: tiles)
      let configuration = try ScreenSharingV2Profile.captureConfiguration(width: 640, height: 360)
      let encoder = try ScreenSharingVideoToolboxTileEncoder(
        configuration: configuration, layout: ScreenSharingV2TileLayout(width: 640, height: 360, count: tiles),
        metrics: metrics)
      return ScreenSharingV2Host(
        transport: transport, encoder: encoder, metrics: metrics, initialBitrate: ScreenSharingV2Profile.bitrateCeiling,
        scheduler: ManualScheduler())
    }

    private static func tileShades(
      _ picture: CVPixelBuffer, expected: [Int] = [40, 90, 140, 190]
    ) -> [(Int, Int)] {
      expected.enumerated().map { tile, shade in
        (Int(TestPixels.luma(of: picture, row: tile * 90 + 45, column: 320)), shade)
      }
    }

    private static func shade(_ frame: ScreenSharingVideoFrame, row: Int) -> Int {
      guard let tile = frame.tiles?.first(where: { $0.rows.contains(row) }) else { return -1 }

      return Int(TestPixels.luma(of: tile.pixelBuffer, row: row - tile.rows.lowerBound, column: 320))
    }

    private static func lumaRow(_ picture: CVPixelBuffer, row: Int) -> UInt8 {
      TestPixels.luma(of: picture, row: row, column: 320)
    }

    private func streamUntilAReferenceIsAcknowledged(
      _ host: ScreenSharingV2Host, decoded: DecodedFrames, viewer: LoopbackMediaTransport
    ) async throws -> Int {
      for index in 1...Self.framesBeforeAnAcknowledgement {
        host.push(try TestPixels.frame(shade: UInt8(index * 7), timestampNs: Int64(index) * 1_000))
        await decoded.arrivals.cancellableWait(for: index)
        if viewer.ltrAcknowledgements.value > 0 { return index }
      }
      Issue.record("No long-term reference was acknowledged in \(Self.framesBeforeAnAcknowledgement) frames.")
      return Self.framesBeforeAnAcknowledgement
    }
  }
}

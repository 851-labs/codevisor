import CodevisorTestSupport
import CoreVideo
import Testing
import VideoToolbox

@testable import ScreenSharing
@testable import ScreenSharingV2

extension HardwareCodecTests {
  @Suite(
    .timeLimit(.minutes(1)),
    .disabled("VCP sessions hold the Mac's hardware encoders until the process exits (851-4009)."))
  struct ScreenSharingVCPEngineTests {
    private static let framesBeforeAnAcknowledgement = 30
    private static let shades: [UInt8] = [40, 90, 140, 190]
    private static let lumaTolerance = 4
    private static let deltaFrames = 6

    static var available: Bool {
      VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) && (try? ScreenSharingVideoProcessing.load()) != nil
    }

    @Test(.enabled(if: available, "No VideoProcessing encoder on this machine."))
    func tileSessionsSendFourFourFourTilesThatComposeIntoOnePicture() async throws {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      let host = Self.host(try Self.vcp(tiles: 4, metrics: ScreenSharingMetrics()), transport: hostSide)
      let viewer = ScreenSharingV2Viewer(transport: viewerSide, metrics: ScreenSharingMetrics())
      let decoded = DecodedFrames(viewer.frames)
      host.start()
      viewer.start()
      defer { host.stop(); viewer.stop() }

      host.push(try TestBGRAPixels.frame(shades: Self.shades, timestampNs: 1_000))
      await decoded.arrivals.cancellableWait(for: 1)

      let first = Array(hostSide.sent.prefix(4))
      #expect(first.map(\.tile).sorted() == [0, 1, 2, 3])
      #expect(first.allSatisfy { $0.isKeyFrame && $0.update.tiles == [0, 1, 2, 3] })
      let picture = try #require(decoded.frames.first?.pixelBuffer)
      #expect(CVPixelBufferGetPixelFormatType(picture) == kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
      #expect(Self.tileLumaErrors(picture).allSatisfy { $0 <= Self.lumaTolerance }, "\(Self.tileLumaErrors(picture))")
    }

    @Test(.enabled(if: available, "No VideoProcessing encoder on this machine."))
    func everyTileDecodesItsDeltaFramesOnItsOwnStream() async throws {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      let host = Self.host(try Self.vcp(tiles: 4, metrics: ScreenSharingMetrics()), transport: hostSide)
      let viewerMetrics = ScreenSharingMetrics()
      let viewer = ScreenSharingV2Viewer(transport: viewerSide, metrics: viewerMetrics)
      let decoded = DecodedFrames(viewer.frames)
      host.start()
      viewer.start()
      defer { host.stop(); viewer.stop() }

      for index in 1...Self.deltaFrames {
        let shades = Self.shades.map { UInt8(truncatingIfNeeded: Int($0) + index * 9) }
        host.push(try TestBGRAPixels.frame(shades: shades, timestampNs: Int64(index) * 1_000))
        await decoded.arrivals.cancellableWait(for: index)
      }

      #expect(decoded.sourceTimestamps == (1...Self.deltaFrames).map { Int64($0) * 1_000 })
      #expect(viewerMetrics.counter("decodeErrors") == 0)
      #expect(hostSide.sent.filter(\.isKeyFrame).count == Self.shades.count)
    }

    @Test(.enabled(if: available, "No VideoProcessing encoder on this machine."))
    func aLostFrameIsRepairedByALongTermReferenceRefreshWithoutAKeyframe() async throws {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      let metrics = ScreenSharingMetrics()
      let host = Self.host(try Self.vcp(tiles: 1, metrics: metrics), transport: hostSide)
      let viewer = ScreenSharingV2Viewer(transport: viewerSide, metrics: ScreenSharingMetrics())
      let decoded = DecodedFrames(viewer.frames)
      host.start()
      viewer.start()
      defer { host.stop(); viewer.stop() }

      let delivered = try await streamUntilAReferenceIsAcknowledged(host, decoded: decoded, viewer: viewerSide)
      hostSide.dropNextFrame()
      host.push(try TestBGRAPixels.frame(shades: [250], timestampNs: 99_000))
      await hostSide.dropped.cancellableWait()
      viewerSide.emit(.frameSkipped(stream: 0, frame: UInt32(delivered)))
      hostSide.emit(.frameLost(stream: 0, frame: UInt32(delivered)))
      await decoded.arrivals.cancellableWait(for: delivered + 1)

      #expect(decoded.sourceTimestamps.last == 99_000)
      #expect(hostSide.sent.last?.refresh == .longTermReference)
      #expect(hostSide.sent.last?.isKeyFrame == false)
      #expect(metrics.counter("encodedKeyFrames") == 1)
    }

    @Test(.enabled(if: available, "No VideoProcessing encoder on this machine."))
    func aFailureMidSessionFallsBackToVideoToolboxWithAKeyframeOnEveryTile() async throws {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      let metrics = ScreenSharingMetrics()
      let failing = FailingTileEncoder(try Self.vcp(tiles: 4, metrics: metrics))
      let fallback = try ScreenSharingVideoToolboxTileEncoder(
        configuration: try Self.configuration(), layout: failing.layout, metrics: metrics)
      let encoder = try ScreenSharingFallbackTileEncoder(primary: failing, fallback: fallback, metrics: metrics)
      let host = Self.host(encoder, transport: hostSide)
      let viewer = ScreenSharingV2Viewer(transport: viewerSide, metrics: ScreenSharingMetrics())
      let decoded = DecodedFrames(viewer.frames)
      host.start()
      viewer.start()
      defer { host.stop(); viewer.stop() }

      host.push(try TestBGRAPixels.frame(shades: Self.shades, timestampNs: 1_000))
      await decoded.arrivals.cancellableWait(for: 1)
      let beforeFailure = hostSide.sent.count
      failing.fail(.throwsOnEncode)
      host.push(try TestBGRAPixels.frame(shades: Self.shades.reversed(), timestampNs: 2_000))
      await decoded.arrivals.cancellableWait(for: 2)

      let afterFailure = Array(hostSide.sent.dropFirst(beforeFailure))
      #expect(afterFailure.map(\.tile).sorted() == [0, 1, 2, 3])
      #expect(afterFailure.allSatisfy { $0.isKeyFrame && $0.sourceTimestampNs == 2_000 })
      #expect(decoded.sourceTimestamps == [1_000, 2_000])
      #expect(metrics.counter("encoderFallbacks") == 1)
      #expect(metrics.snapshot().timings["encoderFallbackToKeyframe"]?.count == 1)
    }

    private static func configuration() throws -> ScreenSharingVideoConfiguration {
      try ScreenSharingV2Profile.captureConfiguration(width: 640, height: 360)
    }

    private static func vcp(tiles: Int, metrics: ScreenSharingMetrics) throws -> ScreenSharingVCPTileEncoder {
      try ScreenSharingVCPTileEncoder(
        configuration: try configuration(), layout: ScreenSharingV2TileLayout(width: 640, height: 360, count: tiles),
        metrics: metrics)
    }

    private static func host(
      _ encoder: any ScreenSharingTileEncoder, transport: LoopbackMediaTransport
    )
      -> ScreenSharingV2Host
    {
      ScreenSharingV2Host(
        transport: transport, encoder: encoder, metrics: ScreenSharingMetrics(),
        initialBitrate: ScreenSharingV2Profile.bitrateCeiling, scheduler: ManualScheduler())
    }

    private static func tileLumaErrors(_ picture: CVPixelBuffer) -> [Int] {
      shades.enumerated().map { tile, shade in
        let luma = Int(TestPixels.luma(of: picture, row: tile * 90 + 45, column: 320))
        return abs(luma - TestBGRAPixels.videoRangeLuma(of: shade))
      }
    }

    private func streamUntilAReferenceIsAcknowledged(
      _ host: ScreenSharingV2Host, decoded: DecodedFrames, viewer: LoopbackMediaTransport
    ) async throws -> Int {
      for index in 1...Self.framesBeforeAnAcknowledgement {
        host.push(try TestBGRAPixels.frame(shades: [UInt8(index * 7)], timestampNs: Int64(index) * 1_000))
        await decoded.arrivals.cancellableWait(for: index)
        if viewer.ltrAcknowledgements.value > 0 { return index }
      }
      Issue.record("No reference was acknowledged in \(Self.framesBeforeAnAcknowledgement) frames.")
      return Self.framesBeforeAnAcknowledgement
    }
  }
}

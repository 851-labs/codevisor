import CodevisorTestSupport
import CoreVideo
import Synchronization
import Testing
import VideoToolbox

@testable import ScreenSharing
@testable import ScreenSharingV2

extension HardwareCodecTests {
  @Suite(.timeLimit(.minutes(1)))
  struct ScreenSharingVCPEngineTests {
    private static let tiles = 2
    private static let framesBeforeAnAcknowledgement = 30
    private static let shades: [UInt8] = [40, 90, 190, 255]
    private static let lumaTolerance = 1
    private static let deltaFrames = 6
    private static let refinedLumaError = 1.5
    private static let refinementGapPastTheNextRefreshNs =
      ScreenSharingV2Profile.refinementGapNs + ScreenSharingV2RefreshPhase().periodNs

    static var available: Bool {
      VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) && (try? ScreenSharingVideoProcessing.load()) != nil
    }

    @Test(.enabled(if: available, "No VideoProcessing encoder on this machine."))
    func tileSessionsSendFourFourFourTilesThatComposeIntoOnePicture() async throws {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      try await HardwareEncoderBudget.require(vcpTiles: Self.tiles)
      let host = Self.host(try Self.vcp(tiles: Self.tiles, metrics: ScreenSharingMetrics()), transport: hostSide)
      let viewer = ScreenSharingV2Viewer(transport: viewerSide, metrics: ScreenSharingMetrics())
      let decoded = DecodedFrames(viewer.frames)
      host.start()
      viewer.start()
      defer { host.stop(); viewer.stop() }

      host.push(try TestBGRAPixels.frame(shades: Self.shades, timestampNs: 1_000))
      await decoded.arrivals.cancellableWait(for: 1)

      let first = Array(hostSide.sent.prefix(Self.tiles))
      #expect(first.map(\.tile).sorted() == Array(0..<Self.tiles))
      #expect(first.allSatisfy { $0.isKeyFrame && $0.update.tiles == Set(0..<Self.tiles) })
      let picture = try #require(decoded.frames.first?.pixelBuffer)
      #expect(CVPixelBufferGetPixelFormatType(picture) == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)
      #expect(Self.bandLumaErrors(picture).allSatisfy { $0 <= Self.lumaTolerance }, "\(Self.bandLumaErrors(picture))")
    }

    @Test(.enabled(if: available, "No VideoProcessing encoder on this machine."))
    func everyTileDecodesItsDeltaFramesOnItsOwnStream() async throws {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      try await HardwareEncoderBudget.require(vcpTiles: Self.tiles)
      let host = Self.host(try Self.vcp(tiles: Self.tiles, metrics: ScreenSharingMetrics()), transport: hostSide)
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
      #expect(hostSide.sent.filter(\.isKeyFrame).count == Self.tiles)
    }

    @Test(.enabled(if: available, "No VideoProcessing encoder on this machine."))
    func refinementPassesTakeTheirLowerQPCapWithoutDropsOrLosingQuality() async throws {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      let scheduler = ManualScheduler()
      let metrics = ScreenSharingMetrics()
      try await HardwareEncoderBudget.require(vcpTiles: 1)
      let everyPass = ScreenSharingV2RefinementPolicy.standard
      let host = Self.host(
        try Self.vcp(tiles: 1, metrics: metrics), transport: hostSide, scheduler, refinement: everyPass)
      let viewer = ScreenSharingV2Viewer(transport: viewerSide, metrics: ScreenSharingMetrics())
      let decoded = DecodedFrames(viewer.frames)
      host.start()
      viewer.start()
      defer { host.stop(); viewer.stop() }

      host.push(try TestBGRAPixels.frame(shades: [128], timestampNs: 1_000))
      await decoded.arrivals.cancellableWait(for: 1)
      host.push(try TestBGRAPixels.noise(timestampNs: 2_000))
      await decoded.arrivals.cancellableWait(for: 2)
      for pass in 1...ScreenSharingV2Profile.refinementPasses {
        scheduler.advance(byNs: Self.refinementGapPastTheNextRefreshNs)
        await decoded.arrivals.cancellableWait(for: 2 + pass)
      }
      host.push(try TestBGRAPixels.frame(shades: [60], timestampNs: 3_000))
      await decoded.arrivals.cancellableWait(for: 3 + ScreenSharingV2Profile.refinementPasses)

      let errors = decoded.frames.dropFirst().dropLast().map { Self.meanNoiseLumaError($0.pixelBuffer) }
      #expect(zip(errors, errors.dropFirst()).allSatisfy { $1 <= $0 }, "\(errors)")
      #expect(errors.last.map { $0 <= Self.refinedLumaError } == true, "\(errors)")
      #expect(decoded.sourceTimestamps.last == 3_000)
      #expect(metrics.counter("encoderDroppedFrames") == 0)
      #expect(metrics.counter("encodeErrors") == 0)
    }

    @Test(.enabled(if: available, "No VideoProcessing encoder on this machine."))
    func aLostFrameIsRepairedByALongTermReferenceRefreshWithoutAKeyframe() async throws {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      let metrics = ScreenSharingMetrics()
      try await HardwareEncoderBudget.require(vcpTiles: 1)
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
    func anAcknowledgementOfAFrameAnEarlierEncoderSentIsNotTakenButItsOwnIs() async throws {
      let earlier = try await Self.firstTileSentByAnEarlierEncoder()
      let transport = LoopbackMediaTransport()
      try await HardwareEncoderBudget.require(vcpTiles: 1)
      let host = Self.host(try Self.vcp(tiles: 1, metrics: ScreenSharingMetrics()), transport: transport)
      host.start()
      defer { host.stop() }
      host.push(try TestBGRAPixels.frame(shades: [60], timestampNs: 1_000))
      await transport.sends.cancellableWait(for: 1)

      transport.emit(.ltrAcked(stream: 0, token: try #require(earlier.ltrToken)))
      transport.emit(.frameLost(stream: 0, frame: 0))
      await transport.sends.cancellableWait(for: 2)
      host.push(try TestBGRAPixels.frame(shades: [90], timestampNs: 2_000))
      await transport.sends.cancellableWait(for: 3)
      transport.emit(.ltrAcked(stream: 0, token: try #require(transport.sent[2].ltrToken)))
      transport.emit(.frameLost(stream: 0, frame: 2))
      await transport.sends.cancellableWait(for: 4)

      #expect(transport.sent.map(\.isKeyFrame) == [true, true, false, false])
      #expect(transport.sent.last?.refresh == .longTermReference)
    }

    @Test(.enabled(if: available, "No VideoProcessing encoder on this machine."))
    func aFrameThatWaitedForContentChangingEveryFrameGetsAFewFrameIntervalsOfBitsNotTheWholeWait() async throws {
      try await HardwareEncoderBudget.require(vcpTiles: 1)
      let encoder = try Self.vcp(tiles: 1, metrics: ScreenSharingMetrics())
      defer { encoder.stop() }
      try encoder.setBitrate(Self.fadingBitrate)
      let sizes = Mutex<[Int]>([])
      let answered = TestSignal()
      encoder.onOutput { output in
        if case .tile(let tile) = output { sizes.withLock { $0.append(tile.accessUnit.count) } }
        answered.signal()
      }
      let startNs = ScreenSharingMetrics.nowNs

      for frame in 1...Self.fadingFrames {
        try encoder.encode(try Self.fading(frame, elapsedNs: ScreenSharingMetrics.nowNs - startNs))
        await answered.cancellableWait(for: frame)
        try await Task.sleep(for: .nanoseconds(Self.longGapNs))
      }

      let encoded = sizes.withLock { $0 }
      try #require(encoded.count > Self.settlingFrames, "only \(encoded.count) frames encoded")
      let farApart = Self.median(encoded.dropFirst(Self.settlingFrames))
      let interval = Self.fadingBitrate / 8 / ScreenSharingV2Profile.framesPerSecond
      #expect(farApart <= Self.allowedIntervals * interval, "\(farApart) bytes a frame, \(interval) a frame interval")
    }

    @Test(.enabled(if: available, "No VideoProcessing encoder on this machine."))
    func aFailureMidSessionFallsBackToVideoToolboxWithAKeyframeOnEveryTile() async throws {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      let metrics = ScreenSharingMetrics()
      try await HardwareEncoderBudget.require(vcpTiles: Self.tiles, videoToolboxTiles: Self.tiles)
      let failing = FailingTileEncoder(try Self.vcp(tiles: Self.tiles, metrics: metrics))
      let configuration = try Self.configuration()
      let encoder = ScreenSharingFallbackTileEncoder(primary: failing, metrics: metrics) { layout in
        try ScreenSharingVideoToolboxTileEncoder(configuration: configuration, layout: layout, metrics: metrics)
      }
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
      #expect(afterFailure.map(\.tile).sorted() == Array(0..<Self.tiles))
      #expect(afterFailure.allSatisfy { $0.isKeyFrame && $0.sourceTimestampNs == 2_000 })
      #expect(decoded.sourceTimestamps == [1_000, 2_000])
      #expect(metrics.counter("encoderFallbacks") == 1)
      #expect(metrics.snapshot().timings["encoderFallbackToKeyframe"]?.count == 1)
    }

    private static func firstTileSentByAnEarlierEncoder() async throws -> ScreenSharingEncodedTile {
      let transport = LoopbackMediaTransport()
      try await HardwareEncoderBudget.require(vcpTiles: 1)
      let host = Self.host(try Self.vcp(tiles: 1, metrics: ScreenSharingMetrics()), transport: transport)
      host.start()
      defer { host.stop() }
      host.push(try TestBGRAPixels.frame(shades: [60], timestampNs: 1_000))
      await transport.sends.cancellableWait(for: 1)
      return try #require(transport.sent.first)
    }

    private static let fadingBitrate = 8_000_000
    private static let fadingFrames = 10
    private static let settlingFrames = 2
    private static let allowedIntervals = 3
    private static let longGapNs: UInt64 = 250_000_000

    private static func fading(_ frame: Int, elapsedNs: Int64) throws -> ScreenSharingTileEncodeRequest {
      let picture = try TestBGRAPixels.frame(shades: [100], timestampNs: Int64(frame) * 1_000)
      let phase = Double(elapsedNs % 4_000_000_000) / 4_000_000_000
      TestBGRAPixels.paint(picture.pixelBuffer, rows: 0..<360, columns: 0..<640) { row, column in
        let from = Double(TestBGRAPixels.noiseShade(row: row / 2, column: column / 2))
        let to = Double(TestBGRAPixels.noiseShade(row: row / 2 + 7_919, column: column / 2))
        return UInt8(from + (to - from) * phase)
      }
      return ScreenSharingTileEncodeRequest(
        pixelBuffer: picture.pixelBuffer, sourceTimestampNs: Int64(frame) * 1_000, capturedNs: Int64(frame) * 1_000,
        update: ScreenSharingTileUpdate(id: UInt32(frame), tiles: [0]),
        contentIntervalsNs: [0: 1_000_000_000 / Int64(ScreenSharingV2Profile.framesPerSecond)])
    }

    private static func median(_ values: some Collection<Int>) -> Int {
      values.sorted()[values.count / 2]
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
      _ encoder: any ScreenSharingTileEncoder, transport: LoopbackMediaTransport,
      _ scheduler: ManualScheduler = ManualScheduler(), refinement: ScreenSharingV2RefinementPolicy? = nil
    )
      -> ScreenSharingV2Host
    {
      ScreenSharingV2Host(
        transport: transport, encoder: encoder, metrics: ScreenSharingMetrics(),
        initialBitrate: ScreenSharingV2Profile.bitrateCeiling, scheduler: scheduler, refinement: refinement)
    }

    private static func meanNoiseLumaError(_ picture: CVPixelBuffer) -> Double {
      let width = CVPixelBufferGetWidth(picture)
      let height = CVPixelBufferGetHeight(picture)
      var total = 0
      for row in 0..<height {
        for column in 0..<width {
          let expected = Int(TestBGRAPixels.noiseShade(row: row, column: column))
          total += abs(Int(TestPixels.luma(of: picture, row: row, column: column)) - expected)
        }
      }
      return Double(total) / Double(width * height)
    }

    private static func bandLumaErrors(_ picture: CVPixelBuffer) -> [Int] {
      shades.enumerated().map { band, shade in
        let luma = Int(TestPixels.luma(of: picture, row: band * 90 + 45, column: 320))
        return abs(luma - Int(shade))
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

import CodevisorTestSupport
import CoreVideo
import Foundation
import Synchronization
import Testing
import VideoToolbox

@testable import ScreenSharing
@testable import ScreenSharingV2

extension HardwareCodecTests {
  @Suite(.timeLimit(.minutes(1)))
  struct ScreenSharingV2EncoderReplacementTests {
    private struct Picture: Equatable, CustomStringConvertible {
      let height: Int
      let shades: [Int]

      init(height: Int = 384, _ shades: [Int]) {
        self.height = height
        self.shades = shades
      }

      init(_ frame: ScreenSharingVideoFrame, tiles: Int) {
        let pixels = frame.pixelBuffer
        let (width, height) = (CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels))
        self.height = height
        shades = (0..<tiles).map { tile in
          let luma = TestPixels.luma(of: pixels, row: (2 * tile + 1) * height / (2 * tiles), column: width / 2)
          return Int((Double(luma) / 10).rounded()) * 10
        }
      }

      var description: String { "\(height): \(shades)" }
    }

    private final class Encoder: Sendable {
      let host: ScreenSharingV2Host
      let tiles: Int
      private let kind: ScreenSharingV2EncoderKind
      private let layout: ScreenSharingV2TileLayout
      private let sent: LoopbackMediaTransport
      private let captures = Atomic<Int64>(0)

      init(_ kind: ScreenSharingV2EncoderKind = .videoToolbox, width: Int = 640, height: Int = 384) async throws {
        self.kind = kind
        tiles = kind == .videoProcessing ? 2 : 4
        layout = ScreenSharingV2TileLayout(width: width, height: height, count: tiles)
        let (hostSide, sent) = LoopbackMediaTransport.pair()
        host = ScreenSharingV2Host(
          transport: hostSide, encoder: try await Self.encoder(kind, layout: layout), metrics: ScreenSharingMetrics(),
          initialBitrate: ScreenSharingV2Profile.bitrateCeiling, scheduler: ManualScheduler())
        self.sent = sent
        host.start()
      }

      private static func encoder(
        _ kind: ScreenSharingV2EncoderKind, layout: ScreenSharingV2TileLayout
      ) async throws -> any ScreenSharingTileEncoder {
        let configuration = try ScreenSharingV2Profile.captureConfiguration(width: layout.width, height: layout.height)
        switch kind {
        case .videoProcessing:
          try await HardwareEncoderBudget.require(vcpTiles: layout.count)
          return try ScreenSharingVCPTileEncoder(
            configuration: configuration, layout: layout, metrics: ScreenSharingMetrics())
        case .videoToolbox:
          try await HardwareEncoderBudget.require(videoToolboxTiles: layout.count)
          return try ScreenSharingVideoToolboxTileEncoder(
            configuration: configuration, layout: layout, metrics: ScreenSharingMetrics())
        }
      }

      func send(_ shades: [UInt8], changing changed: Int? = nil) async throws -> [ScreenSharingReceivedFrame] {
        host.push(try capture(shades))
        var frames: [ScreenSharingReceivedFrame] = []
        while frames.count < changed ?? tiles, case .frame(let frame)? = await sent.nextEvent() {
          frames.append(frame)
        }
        return frames
      }

      private func capture(_ shades: [UInt8]) throws -> ScreenSharingVideoFrame {
        let timestampNs = captures.add(1_000, ordering: .relaxed).newValue
        guard kind == .videoProcessing else {
          return try TestPixels.frame(
            width: layout.width, height: layout.height, shades: shades, timestampNs: timestampNs)
        }

        return try TestBGRAPixels.frame(
          width: layout.width, height: layout.height, shades: shades, timestampNs: timestampNs)
      }
    }

    private let arriving = LoopbackMediaTransport()
    private let viewer: ScreenSharingV2Viewer
    private let decoded: DecodedFrames

    init() {
      viewer = ScreenSharingV2Viewer(transport: arriving, metrics: ScreenSharingMetrics())
      decoded = DecodedFrames(viewer.frames)
      viewer.start()
    }

    private func arrive(_ frames: [ScreenSharingReceivedFrame]) {
      for frame in frames { arriving.emit(.frame(frame)) }
    }

    private func pictures(tiles: Int = 4) -> [Picture] {
      decoded.frames.map { Picture($0, tiles: tiles) }
    }

    private func fromAHostThatDoesNotNameItsEncoder(
      _ frames: [ScreenSharingReceivedFrame]
    ) -> [ScreenSharingReceivedFrame] {
      frames.map {
        ScreenSharingReceivedFrame(
          stream: $0.stream, frame: $0.frame, isKeyFrame: $0.isKeyFrame, ltrToken: $0.ltrToken,
          meta: Data($0.meta.prefix(ScreenSharingV2FrameMeta.byteCount)), payload: $0.payload, assemblingUs: 0,
          recovery: .none)
      }
    }

    private func aSameSizeReplacementStartsThePictureOver(_ kind: ScreenSharingV2EncoderKind) async throws {
      defer { viewer.stop() }
      let old = try await Encoder(kind)
      let tiles = old.tiles
      let whole = { (shade: Int) in Picture(Array(repeating: shade, count: tiles)) }
      arrive(try await old.send([40]))
      arrive(try await old.send([90]).filter { $0.stream == 0 })
      old.host.stop()

      let new = try await Encoder(kind)
      defer { new.host.stop() }
      arrive(try await new.send([140]))
      await decoded.arrivals.cancellableWait(for: 2)
      #expect(pictures(tiles: tiles) == [whole(40), whole(140)])

      let lowerTilesChanged = [140] + Array(repeating: UInt8(190), count: tiles - 1)
      arrive(try await new.send(lowerTilesChanged, changing: tiles - 1))
      await decoded.arrivals.cancellableWait { pictures(tiles: tiles).last?.shades.last == 190 }
      #expect(pictures(tiles: tiles).last == Picture(lowerTilesChanged.map(Int.init)))
    }

    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func aNewEncoderAtTheSameSizeStartsThePictureOverWithoutTheOldEncodersTiles() async throws {
      try await aSameSizeReplacementStartsThePictureOver(.videoToolbox)
    }

    @Test(.enabled(if: ScreenSharingVCPEngineTests.available, "No VideoProcessing encoder on this machine."))
    func aNewVideoProcessingEncoderAtTheSameSizeStartsThePictureOverWithoutTheOldEncodersTiles() async throws {
      try await aSameSizeReplacementStartsThePictureOver(.videoProcessing)
    }

    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func aHostThatDoesNotNameItsEncoderStillMovesThePictureToItsNewSize() async throws {
      defer { viewer.stop() }
      let old = try await Encoder()
      arrive(fromAHostThatDoesNotNameItsEncoder(try await old.send([40])))
      old.host.stop()

      let new = try await Encoder(width: 1280, height: 768)
      defer { new.host.stop() }
      arrive(fromAHostThatDoesNotNameItsEncoder(try await new.send([140])))
      await decoded.arrivals.cancellableWait(for: 2)

      #expect(pictures() == [Picture([40, 40, 40, 40]), Picture(height: 768, [140, 140, 140, 140])])
    }

    @Test(
      .enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."),
      arguments: [384, 768])
    func aLateFrameFromTheReplacedEncoderLeavesTheNewEncodersPictureAlone(newHeight: Int) async throws {
      defer { viewer.stop() }
      let old = try await Encoder()
      arrive(try await old.send([40]))
      let late = try await old.send([40, 40, 90, 40], changing: 1)
      old.host.stop()

      let new = try await Encoder(width: newHeight * 5 / 3, height: newHeight)
      defer { new.host.stop() }
      let first = try await new.send([140])
      arrive(first.filter { $0.stream != 2 } + late + first.filter { $0.stream == 2 })
      await decoded.arrivals.cancellableWait(for: 2)

      #expect(pictures() == [Picture([40, 40, 40, 40]), Picture(height: newHeight, [140, 140, 140, 140])])
    }
  }
}

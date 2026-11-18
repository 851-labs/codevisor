import CodevisorTestSupport
import CoreGraphics
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

      init(_ frame: ScreenSharingVideoFrame) {
        let pixels = frame.pixelBuffer
        let (width, height) = (CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels))
        self.height = height
        shades = (0..<4).map { tile in
          let luma = TestPixels.luma(of: pixels, row: tile * height / 4 + height / 8, column: width / 2)
          return Int((Double(luma) / 10).rounded()) * 10
        }
      }

      var description: String { "\(height): \(shades)" }
    }

    private final class Encoder: Sendable {
      let host: ScreenSharingV2Host
      private let layout: ScreenSharingV2TileLayout
      private let sent: LoopbackMediaTransport
      private let captures = Atomic<Int64>(0)

      init(width: Int = 640, height: Int = 384) async throws {
        try await HardwareEncoderBudget.require(videoToolboxTiles: 4)
        let (hostSide, sent) = LoopbackMediaTransport.pair()
        let metrics = ScreenSharingMetrics()
        layout = ScreenSharingV2TileLayout(width: width, height: height, count: 4)
        let encoder = try ScreenSharingVideoToolboxTileEncoder(
          configuration: try ScreenSharingV2Profile.captureConfiguration(width: width, height: height),
          layout: layout, metrics: metrics)
        host = ScreenSharingV2Host(
          transport: hostSide, encoder: encoder, metrics: metrics,
          initialBitrate: ScreenSharingV2Profile.bitrateCeiling, scheduler: ManualScheduler())
        self.sent = sent
        host.start()
      }

      func send(_ shades: [UInt8], changing tiles: Range<Int>? = nil) async throws -> [ScreenSharingReceivedFrame] {
        let changed = tiles.map { tiles in
          CGRect(
            x: 0, y: tiles.lowerBound * layout.tileHeight, width: layout.width,
            height: tiles.count * layout.tileHeight)
        }
        let timestampNs = captures.add(1_000, ordering: .relaxed).newValue
        host.push(
          try TestPixels.frame(
            width: layout.width, height: layout.height, shades: shades, timestampNs: timestampNs,
            dirtyRects: changed.map { [$0] }))
        var frames: [ScreenSharingReceivedFrame] = []
        while frames.count < tiles?.count ?? 4, case .frame(let frame)? = await sent.nextEvent() {
          frames.append(frame)
        }
        return frames
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

    private var pictures: [Picture] { decoded.frames.map(Picture.init) }

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

    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func aNewEncoderAtTheSameSizeStartsThePictureOverWithoutTheOldEncodersTiles() async throws {
      defer { viewer.stop() }
      let old = try await Encoder()
      arrive(try await old.send([40]))
      arrive(try await old.send([90]).filter { $0.stream == 0 })
      old.host.stop()

      let new = try await Encoder()
      defer { new.host.stop() }
      arrive(try await new.send([140]))
      await decoded.arrivals.cancellableWait(for: 2)
      #expect(pictures == [Picture([40, 40, 40, 40]), Picture([140, 140, 140, 140])])

      arrive(try await new.send([140, 190, 190, 190], changing: 1..<4))
      await decoded.arrivals.cancellableWait { pictures.last?.shades.suffix(3) == [190, 190, 190] }
      #expect(pictures.last == Picture([140, 190, 190, 190]))
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

      #expect(pictures == [Picture([40, 40, 40, 40]), Picture(height: 768, [140, 140, 140, 140])])
    }

    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func aLateFrameFromTheOldSizeLeavesTheNewSizesPictureAlone() async throws {
      defer { viewer.stop() }
      let old = try await Encoder()
      arrive(try await old.send([40]))
      let late = try await old.send([40, 40, 90, 40], changing: 2..<3)
      old.host.stop()

      let new = try await Encoder(width: 1280, height: 768)
      defer { new.host.stop() }
      let first = try await new.send([140])
      arrive(first.filter { $0.stream != 2 } + late + first.filter { $0.stream == 2 })
      await decoded.arrivals.cancellableWait(for: 2)

      #expect(pictures == [Picture([40, 40, 40, 40]), Picture(height: 768, [140, 140, 140, 140])])
    }
  }
}

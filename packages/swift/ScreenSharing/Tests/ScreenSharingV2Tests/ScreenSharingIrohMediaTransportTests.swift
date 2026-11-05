import CodevisorNet
import CodevisorTestSupport
import Testing
import VideoToolbox

@testable import ScreenSharing
@testable import ScreenSharingV2

extension HardwareCodecTests {
  @Suite(.timeLimit(.minutes(1)))
  struct ScreenSharingIrohMediaTransportTests {
    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func framesCrossARealMediaSessionInOrderWithTheirInBandIdentity() async throws {
      try await HardwareEncoderBudget.require(videoToolboxTiles: 1)
      let link = try await IrohLoopback.connect()
      defer { link.close() }
      let metrics = ScreenSharingMetrics()
      let encoder = try ScreenSharingVideoToolboxTileEncoder(
        configuration: try ScreenSharingV2Profile.captureConfiguration(width: 640, height: 360), metrics: metrics)
      let host = ScreenSharingV2Host(
        transport: link.host, encoder: encoder, metrics: metrics, initialBitrate: ScreenSharingV2Profile.bitrateCeiling,
        scheduler: ManualScheduler())
      let viewer = ScreenSharingV2Viewer(transport: link.viewer, metrics: ScreenSharingMetrics())
      let decoded = DecodedFrames(viewer.frames)
      host.start()
      viewer.start()
      defer { host.stop(); viewer.stop() }

      for index in 1...3 {
        host.push(try TestPixels.frame(shade: UInt8(index * 40), timestampNs: Int64(index) * 1_000))
        await decoded.arrivals.cancellableWait(for: index)
      }

      #expect(decoded.sourceTimestamps == [1_000, 2_000, 3_000])
    }
  }
}

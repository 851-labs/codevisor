import CodevisorTestSupport
import Testing
import VideoToolbox

@testable import ScreenSharing
@testable import ScreenSharingV2

@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingV2EngineTests {
  private static let framesBeforeAnAcknowledgement = 30

  @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
  func aDroppedFrameIsRepairedByALongTermReferenceRefreshWithoutAKeyframe() async throws {
    let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
    let metrics = ScreenSharingMetrics()
    let encoder = try ScreenSharingVideoToolboxTileEncoder(
      configuration: try ScreenSharingV2Profile.captureConfiguration(width: 640, height: 360), metrics: metrics)
    let host = ScreenSharingV2Host(transport: hostSide, encoder: encoder, metrics: metrics)
    let viewer = ScreenSharingV2Viewer(transport: viewerSide, metrics: ScreenSharingMetrics())
    let decoded = DecodedFrames(viewer.frames)
    host.start()
    viewer.start()
    defer { host.stop(); viewer.stop() }

    let delivered = try await streamUntilAReferenceIsAcknowledged(host, decoded: decoded, viewer: viewerSide)
    hostSide.dropNextFrame()
    host.push(try TestPixels.frame(shade: 250, timestampNs: 99_000))
    await hostSide.dropped.wait()
    viewerSide.emit(.frameSkipped(stream: 0, frame: UInt32(delivered)))
    hostSide.emit(.frameLost(stream: 0, frame: UInt32(delivered)))
    await decoded.arrivals.wait(for: delivered + 1)

    #expect(decoded.sourceTimestamps.last == 99_000)
    #expect(hostSide.sent.last?.refresh == .longTermReference)
    #expect(hostSide.sent.last?.isKeyFrame == false)
    #expect(metrics.counter("encodedKeyFrames") == 1)
  }

  private func streamUntilAReferenceIsAcknowledged(
    _ host: ScreenSharingV2Host, decoded: DecodedFrames, viewer: LoopbackMediaTransport
  ) async throws -> Int {
    for index in 1...Self.framesBeforeAnAcknowledgement {
      host.push(try TestPixels.frame(shade: UInt8(index * 7), timestampNs: Int64(index) * 1_000))
      await decoded.arrivals.wait(for: index)
      if viewer.ltrAcknowledgements.value > 0 { return index }
    }
    Issue.record("No long-term reference was acknowledged in \(Self.framesBeforeAnAcknowledgement) frames.")
    return Self.framesBeforeAnAcknowledgement
  }
}

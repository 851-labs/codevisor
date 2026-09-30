import CodevisorTestSupport
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC

/// HDR end to end inside one process (851-2380): a viewer whose screen can show HDR says so on the
/// video format channel, and a 10-bit Display P3 PQ capture crosses WebRTC as Main 4:4:4 10 and
/// reaches the viewer's mailbox still 10-bit. The time limit is a deadlock guard for the hardware
/// codec and the loopback transport; every wait is on a callback.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingHDRLoopbackTests {
  nonisolated static let hasEncoder: Bool = {
    guard let configuration = try? ScreenSharingVideoConfiguration(width: 320, height: 192),
      let encoder = try? ScreenSharingEncoder(
        configuration: configuration, metrics: ScreenSharingMetrics(), useLowLatencyRateControl: false,
        codec: .hevc444, dynamicRange: .high)
    else { return false }
    encoder.stop()
    return true
  }()

  @Test(.enabled(if: hasEncoder, "No hardware HEVC Main 4:4:4 10 encoder on this machine."))
  func aTenBitCaptureReachesTheViewerAsTenBitAfterTheViewerAskedForHDR() async throws {
    let configuration = try ScreenSharingVideoConfiguration(width: 320, height: 192)
    let hostMetrics = ScreenSharingMetrics()
    let sender = try ScreenSharingSender(configuration: configuration, metrics: hostMetrics)
    let receiver = try ScreenSharingReceiver(configuration: configuration, metrics: ScreenSharingMetrics())
    defer {
      sender.close()
      receiver.close()
    }
    let connected = TestSignal()
    sender.onConnectionChanged = { if $0 == "connected" { connected.signal() } }
    let heard = TestSignal()
    var viewerSaid: [ScreenSharingVideoFormatMessage] = []
    sender.videoFormatChannel.onMessage = {
      viewerSaid.append($0)
      heard.signal()
    }
    let arrived = TestSignal()
    receiver.mailbox.onFrameAvailable { arrived.signal() }

    // Reported before the channel exists: held, and sent once it opens.
    receiver.setDisplayHighDynamicRange(true)
    let offer = try await receiver.makeDescription(offer: true)
    try await sender.accept(offer)
    let answer = try await sender.makeDescription(offer: false)
    #expect(ScreenSharingVideoCodec.negotiated(inDescription: answer.sdp) == .hevc444)
    try await receiver.accept(answer)
    await connected.wait()
    await heard.wait()
    #expect(viewerSaid == [.viewer(highDynamicRange: true)])

    sender.frameSender.push(
      ScreenSharingVideoFrame(pixelBuffer: try Self.hdrPicture(width: 320, height: 192), timestampNs: Self.now()))
    await arrived.wait()
    let frame = try #require(receiver.mailbox.take())
    #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange)
    let labels = hostMetrics.snapshot().labels
    #expect(labels["encodedBitDepth"] == "10" && labels["encoderDynamicRange"] == "high")
  }

  nonisolated static func now() -> Int64 {
    CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000_000, method: .default).value
  }

  /// What ScreenCaptureKit's HDR preset delivers: 10-bit full-range 4:4:4, here a flat mid grey.
  static func hdrPicture(width: Int, height: Int) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    CVPixelBufferCreate(nil, width, height, ScreenSharingDynamicRange.highCapturePixelFormat, attributes, &created)
    let buffer = try #require(created)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<2 {
      let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
      let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
      for row in 0..<height {
        let line = (base + row * stride).assumingMemoryBound(to: UInt16.self)
        for index in 0..<(width * (plane == 0 ? 1 : 2)) { line[index] = 512 << 6 }
      }
    }
    return buffer
  }
}

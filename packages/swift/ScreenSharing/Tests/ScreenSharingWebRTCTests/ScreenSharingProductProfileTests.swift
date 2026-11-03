import CodevisorTestSupport
import CoreVideo
import Testing
@preconcurrency import WebRTC
@testable import ScreenSharing
@testable import ScreenSharingWebRTC

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingProductProfileTests {
  nonisolated static let hasEncoder: Bool = {
    guard let configuration = try? ScreenSharingVideoConfiguration(width: 320, height: 192),
      let encoder = try? ScreenSharingEncoder(
        configuration: configuration, metrics: ScreenSharingMetrics(), useLowLatencyRateControl: false,
        codec: .hevc444)
    else { return false }
    encoder.stop()
    return true
  }()

  @Test(.enabled(if: hasEncoder, "No hardware HEVC Main 4:4:4 encoder on this machine."))
  func aProductSenderStreamsWithTheProductSettings() async throws {
    let configuration = try ScreenSharingProductProfile.captureConfiguration(width: 320, height: 192)
    let hostMetrics = ScreenSharingMetrics()
    let sender = try await ScreenSharingSender(configuration: configuration, metrics: hostMetrics)
    let receiver = try await ScreenSharingReceiver(configuration: .init(), metrics: ScreenSharingMetrics())
    defer {
      sender.close()
      receiver.close()
    }
    let connected = TestSignal()
    sender.onConnectionChanged = { if $0 == "connected" { connected.signal() } }
    let arrived = TestSignal()
    receiver.mailbox.onFrameAvailable { arrived.signal() }

    let offer = try await receiver.makeDescription(offer: true)
    try await sender.accept(offer)
    let answer = try await sender.makeDescription(offer: false)
    #expect(ScreenSharingVideoCodec.negotiated(inDescription: answer.sdp) == .hevc444)
    try await receiver.accept(answer)
    await connected.cancellableWait()
    sender.frameSender.push(
      ScreenSharingVideoFrame(
        pixelBuffer: try Self.picture(width: 320, height: 192), timestampNs: ScreenSharingHDRLoopbackTests.now()))
    await arrived.cancellableWait()
    let receivedBytes = await ScreenSharingInboundVideo(transport: receiver.transport).bytesReceived()
    #expect((receivedBytes ?? 0) > 0)

    let labels = hostMetrics.snapshot().labels
    #expect(labels["videoCodec"] == "hevc444")
    #expect(labels["encoderMaximumPendingFrames"] == "3")
    #expect(labels["encoderKeyframeIntervalSeconds"] == "60")
    #expect(await sender.transport.inspect { $0.map(Self.maximumBitrates) } == [45_000_000])
  }

  @Test func displaysAreCapturedScaledIntoTheBoxAtTheBitrateCeiling() throws {
    let fit = { (width: Int, height: Int) in
      let configuration = try ScreenSharingProductProfile.captureConfiguration(width: width, height: height)
      #expect(configuration.bitrate == 45_000_000 && configuration.framesPerSecond == 60)
      return [configuration.width, configuration.height]
    }
    #expect(try fit(3024, 1964) == [2216, 1440], "a 14-inch MacBook Pro: the size measured on an M1 Pro")
    #expect(try fit(5120, 2880) == [2560, 1440], "a 5K display")
    #expect(try fit(1920, 1080) == [1920, 1080], "smaller displays aren't scaled up")
    #expect(try fit(3456, 2234) == [2226, 1440])
  }

  private nonisolated static func maximumBitrates(_ connection: RTCPeerConnection) -> [Int] {
    connection.senders.flatMap { $0.parameters.encodings.compactMap { $0.maxBitrateBps?.intValue } }
  }

  private static func picture(width: Int, height: Int) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
    return try #require(created)
  }
}

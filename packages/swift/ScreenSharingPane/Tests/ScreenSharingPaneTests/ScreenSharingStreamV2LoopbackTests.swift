import CodevisorClient
import CodevisorNet
import CodevisorTestSupport
import CoreVideo
import Foundation
import ScreenSharing
import ScreenSharingV2
import Testing
import VideoToolbox

@testable import ScreenSharingPane

extension HardwareCodecTests {
  @MainActor
  @Suite("Touch viewer over engine v2, in process", .timeLimit(.minutes(1)))
  struct ScreenSharingStreamV2LoopbackTests {
    @Test(
      "A touch viewer that asks for 4:2:0 gets VideoToolbox video over QUIC and asks for control on it",
      .enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func watchesAndControlsAHost() async throws {
      let pair = try await IrohPair.connect()
      defer { pair.close() }
      let transport = StreamTransport(engines: ["v2"], v2StartStatus: "connecting")
      let configuration = try ScreenSharingV2Profile.captureConfiguration(width: 640, height: 360)
      let host = ScreenSharingV2HostLink(configuration: configuration, metrics: ScreenSharingMetrics()) {
        configuration, metrics in
        let chroma = await transport.starts.last?.chroma
        return try await ScreenSharingV2Encoders.make(
          .forViewer(chroma: chroma), configuration: configuration, metrics: metrics)
      }
      defer { host.close() }
      let accepted = Task { try await host.accept(pair.host) { $0 == StreamHarness.grant.token ? nil : "wrong token" } }
      var sponsor = ScreenSharingStreamSponsor(
        workspaceId: UUID(), paneId: UUID(),
        client: CodevisorServerClient(config: .init(requestTransport: transport)), openTunnel: nil,
        v2: ScreenSharingV2Connector(
          address: { StreamHarness.viewerMedia },
          connect: { _ in ScreenSharingV2ViewingSession(connection: pair.viewer) },
          chroma: { .subsampled }))
      sponsor.makeWebRTC = { _ in throw ScreenSharingError.unavailable("This test never falls back to WebRTC.") }
      let stream = ScreenSharingStream(displayId: "display", sponsor: sponsor)
      stream.start()
      defer { stream.stop() }
      try await accepted.value
      await awaitObserved { stream.session != nil }
      let session = try #require(stream.session)

      let arrived = TestSignal()
      session.frames.onFrameAvailable { arrived.signal() }
      let pushing = Task { @MainActor in
        for index in 1...500 {
          host.frameRouter.push(
            try Self.frame(shade: UInt8(40 + index % 160), timestampNs: Int64(index) * 16_000_000))
          try await Task.sleep(for: .milliseconds(10))
        }
      }
      defer { pushing.cancel() }
      await arrived.cancellableWait()
      let frame = try #require(session.frames.take())
      #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 640 && CVPixelBufferGetHeight(frame.pixelBuffer) == 360)
      #expect(session.metrics.snapshot().labels["decoder"] == "VideoToolbox HEVC 4:2:0")
      #expect(await transport.starts.map(\.chroma) == ["420"])

      stream.presentedFirstFrame()
      await awaitObserved { stream.diagnostics.engine != nil }
      #expect(stream.diagnostics.engine == "v2 · QUIC" && stream.diagnostics.route == "Direct")

      let requested = TestSignal()
      host.linkChannels.control.onMessage = { if case .request = $0 { requested.signal() } }
      stream.control?.send([.move(ScreenSharingPointer(x: 0.5, y: 0.5), modifiers: 0)])
      await requested.cancellableWait()
      #expect(stream.control?.state == .requesting)
    }

    private static func frame(shade: UInt8, timestampNs: Int64) throws -> ScreenSharingVideoFrame {
      var buffer: CVPixelBuffer?
      let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
      CVPixelBufferCreate(
        kCFAllocatorDefault, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
      guard let buffer else { throw ScreenSharingError.unavailable("No pixel buffer.") }

      CVPixelBufferLockBaseAddress(buffer, [])
      defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
      for plane in 0..<2 {
        let value = plane == 0 ? Int32(shade) : 128
        memset(
          CVPixelBufferGetBaseAddressOfPlane(buffer, plane), value,
          CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
      }
      return ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: timestampNs)
    }
  }
}

private struct IrohPair {
  let host: ScreenSharingV2IrohConnection
  let viewer: ScreenSharingV2IrohConnection
  private let endpoints: [NetEndpointHandle]

  static func connect() async throws -> IrohPair {
    let hostEndpoint = try await bind()
    let viewerEndpoint = try await bind()
    async let accepted = hostEndpoint.accept()
    let viewerConnection = try await viewerEndpoint.connect(addr: hostEndpoint.addr(), alpn: mediaAlpn(), cancel: nil)
    guard let hostConnection = try await accepted else {
      throw ScreenSharingError.unavailable("The host endpoint closed before accepting.")
    }

    return IrohPair(
      host: ScreenSharingV2IrohConnection(hostConnection), viewer: ScreenSharingV2IrohConnection(viewerConnection),
      endpoints: [hostEndpoint, viewerEndpoint])
  }

  func close() {
    for endpoint in endpoints { Task { await endpoint.close() } }
  }

  private static func bind() async throws -> NetEndpointHandle {
    try await netBindEndpoint(
      config: NetEndpointConfig(
        secretKeyHex: netGenerateSecretKeyHex(), relays: [], trustAnchorsPem: [], pathPolicy: "direct-only",
        alpns: [mediaAlpn()]))
  }
}

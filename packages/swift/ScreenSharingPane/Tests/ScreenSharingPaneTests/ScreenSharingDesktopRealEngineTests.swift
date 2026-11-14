import CodevisorClient
import CodevisorNet
import CodevisorTestSupport
import CoreVideo
import Foundation
import ScreenSharing
import ScreenSharingConnectionTesting
import Testing
import VideoToolbox

@testable import ScreenSharingPane
@testable import ScreenSharingV2

extension HardwareCodecTests {
  @MainActor
  @Suite("The phone's Desktop over the real engine, in process", .timeLimit(.minutes(1)))
  struct ScreenSharingDesktopRealEngineTests {
    @Test(
      "A phone that asks for 4:2:0 goes live on hardware-decoded video over QUIC and asks for control on it",
      .enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func watchesAndControlsAHost() async throws {
      try await HardwareEncoderBudget.require(sessions: 1, opening: Self.openEncoderSession)
      let pair = try await IrohPair.connect()
      defer { pair.close() }
      let harness = DesktopsHarness()
      harness.connector = ScreenSharingV2Connector(
        address: { FakeMedia.address },
        connect: { _ in ScreenSharingV2ViewingSession(connection: pair.viewer) },
        chroma: { ScreenSharingPaneModel.requestedChroma })
      let host = try Self.host(encodingFor: harness.host)
      defer { host.close() }
      let accepted = Task { try await host.accept(pair.host) { $0 == FakeHost.grant.token ? nil : "wrong token" } }
      let model = try #require(harness.model())
      harness.show(model)
      try await accepted.value
      await awaitObserved { model.session != nil }
      let session = try #require(model.session)
      let decoded = session.frames.tap(UUID())

      let pushing = Task { @MainActor in
        for index in 1...500 {
          host.frameRouter.push(
            try Self.frame(shade: UInt8(40 + index % 160), timestampNs: Int64(index) * 16_000_000))
          try await Task.sleep(for: .milliseconds(10))
        }
      }
      defer { pushing.cancel() }
      await awaitObserved { model.isViewing }
      let frame = try #require(decoded.take())
      #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 640 && CVPixelBufferGetHeight(frame.pixelBuffer) == 360)
      #expect(session.metrics.snapshot().labels["decoder"] == "VideoToolbox HEVC 4:2:0")
      #expect(harness.host.starts.map(\.chroma) == ["420"])

      await awaitObserved { model.diagnostics?.engine != nil }
      #expect(model.diagnostics?.engine == "v2 · QUIC" && model.diagnostics?.route == "Direct")

      let requested = TestSignal()
      host.linkChannels.control.onMessage = { if case .request = $0 { requested.signal() } }
      model.tap(at: ScreenSharingPointer(x: 0.5, y: 0.5), location: .zero, time: 0)
      await requested.cancellableWait()
      #expect(model.control?.state == .requesting)
    }

    private static func host(encodingFor fake: FakeHost) throws -> ScreenSharingV2HostLink {
      let configuration = try ScreenSharingV2Profile.captureConfiguration(width: 640, height: 360)
      return ScreenSharingV2HostLink(configuration: configuration, metrics: ScreenSharingMetrics()) {
        configuration, metrics in
        let chroma = await fake.starts.last?.chroma
        return try await ScreenSharingV2Encoders.make(
          .forViewer(chroma: chroma), configuration: configuration, metrics: metrics)
      }
    }

    nonisolated private static func openEncoderSession(width: Int, height: Int) -> VTCompressionSession? {
      try? ScreenSharingVideoToolboxSessionFactory(
        width: width, height: height, framesPerSecond: 60, bitrate: 1_000_000
      )
      .make()
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

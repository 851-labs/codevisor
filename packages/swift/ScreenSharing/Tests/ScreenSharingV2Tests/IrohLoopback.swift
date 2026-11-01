import CodevisorNet

@testable import ScreenSharingV2

struct IrohLoopback {
  let host: ScreenSharingIrohMediaTransport
  let viewer: ScreenSharingIrohMediaTransport
  private let endpoints: [NetEndpointHandle]

  static func connect() async throws -> IrohLoopback {
    let hostEndpoint = try await bind()
    let viewerEndpoint = try await bind()
    async let accepted = hostEndpoint.accept()
    let viewerConnection = try await viewerEndpoint.connect(addr: hostEndpoint.addr(), alpn: mediaAlpn(), cancel: nil)
    guard let hostConnection = try await accepted else { throw ScreenSharingV2FrameMetaError.unsupported }

    let config = ScreenSharingIrohMediaTransport.sessionConfig
    return IrohLoopback(
      host: ScreenSharingIrohMediaTransport(session: await hostConnection.openMediaSession(config: config)),
      viewer: ScreenSharingIrohMediaTransport(session: await viewerConnection.openMediaSession(config: config)),
      endpoints: [hostEndpoint, viewerEndpoint])
  }

  func close() {
    host.close()
    viewer.close()
    for endpoint in endpoints { Task { await endpoint.close() } }
  }

  private static func bind() async throws -> NetEndpointHandle {
    try await netBindEndpoint(
      config: NetEndpointConfig(
        secretKeyHex: netGenerateSecretKeyHex(), relays: [], trustAnchorsPem: [], pathPolicy: "direct-only",
        alpns: [mediaAlpn()]))
  }
}

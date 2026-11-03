import CodevisorNet

@testable import ScreenSharingV2

struct IrohConnectionPair {
  let host: ScreenSharingV2IrohConnection
  let viewer: ScreenSharingV2IrohConnection
  private let endpoints: [NetEndpointHandle]

  static func connect() async throws -> IrohConnectionPair {
    let hostEndpoint = try await bind()
    let viewerEndpoint = try await bind()
    async let accepted = hostEndpoint.accept()
    let viewerConnection = try await viewerEndpoint.connect(addr: hostEndpoint.addr(), alpn: mediaAlpn(), cancel: nil)
    guard let hostConnection = try await accepted else { throw ScreenSharingV2FrameMetaError.unsupported }

    return IrohConnectionPair(
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

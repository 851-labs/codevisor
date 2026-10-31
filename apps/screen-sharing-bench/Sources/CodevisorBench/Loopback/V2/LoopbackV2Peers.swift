import CodevisorNet
import ScreenSharing
import ScreenSharingBench
import ScreenSharingV2

@MainActor
final class LoopbackV2Peers {
  private static let connectTimeout = Duration.seconds(15)
  private static let loopbackHost = "127.0.0.1"

  let hostMetrics: ScreenSharingMetrics
  let viewerMetrics: ScreenSharingMetrics
  let host: ScreenSharingV2Host
  let viewer: ScreenSharingV2Viewer
  let hostTap: V2MediaTap
  let viewerTap: V2MediaTap
  private let endpoints: [NetEndpointHandle]
  private let connections: [NetConnectionHandle]

  static func connect(
    through relay: LoopbackRelay, configuration: ScreenSharingVideoConfiguration
  ) async throws -> LoopbackV2Peers {
    let hostEndpoint = try await bindPinned()
    let viewerEndpoint: NetEndpointHandle
    do {
      viewerEndpoint = try await bindPinned()
    } catch {
      await hostEndpoint.close()
      throw error
    }
    do {
      return try await connect(host: hostEndpoint, viewer: viewerEndpoint, relay: relay, configuration: configuration)
    } catch {
      await hostEndpoint.close()
      await viewerEndpoint.close()
      throw error
    }
  }

  private static func connect(
    host hostEndpoint: NetEndpointHandle, viewer viewerEndpoint: NetEndpointHandle, relay: LoopbackRelay,
    configuration: ScreenSharingVideoConfiguration
  ) async throws -> LoopbackV2Peers {
    relay.connect(
      host: try loopbackAddress(of: hostEndpoint.addr()), viewer: try loopbackAddress(of: viewerEndpoint.addr()))
    let relayAddress = "\(loopbackHost):\(relay.hostFacing.port)"
    let target = NetTunnelAddr(endpointId: hostEndpoint.addr().endpointId, relayUrl: nil, directAddrs: [relayAddress])
    let hostMetrics = ScreenSharingMetrics()
    let encoder = try ScreenSharingVideoToolboxTileEncoder(configuration: configuration, metrics: hostMetrics)
    let deadline = ContinuousClock.now + connectTimeout
    async let accepted = V2Accept.connection(on: hostEndpoint, until: deadline)
    let viewerConnection: NetConnectionHandle
    do {
      viewerConnection = try await viewerEndpoint.connect(addr: target, alpn: mediaAlpn(), cancel: nil)
    } catch {
      await hostEndpoint.close()
      _ = try? await accepted
      throw error
    }
    guard let hostConnection = try await accepted else {
      viewerConnection.close(code: 0, reason: "no host")
      throw LoopbackError.connectionTimedOut
    }

    let hostTap = V2MediaTap(
      ScreenSharingIrohMediaTransport(
        session: await hostConnection.openMediaSession(config: ScreenSharingIrohMediaTransport.sessionConfig)))
    let viewerTap = V2MediaTap(
      ScreenSharingIrohMediaTransport(
        session: await viewerConnection.openMediaSession(config: ScreenSharingIrohMediaTransport.sessionConfig)))
    return LoopbackV2Peers(
      host: ScreenSharingV2Host(transport: hostTap, encoder: encoder, metrics: hostMetrics),
      viewer: ScreenSharingV2Viewer(transport: viewerTap, metrics: ScreenSharingMetrics()), taps: (hostTap, viewerTap),
      endpoints: [hostEndpoint, viewerEndpoint],
      connections: [hostConnection, viewerConnection])
  }

  private init(
    host: ScreenSharingV2Host, viewer: ScreenSharingV2Viewer, taps: (host: V2MediaTap, viewer: V2MediaTap),
    endpoints: [NetEndpointHandle], connections: [NetConnectionHandle]
  ) {
    self.host = host
    self.viewer = viewer
    hostMetrics = host.metrics
    viewerMetrics = viewer.metrics
    hostTap = taps.host
    viewerTap = taps.viewer
    self.endpoints = endpoints
    self.connections = connections
  }

  func start() {
    host.start()
    viewer.start()
  }

  func close() async {
    host.stop()
    viewer.stop()
    for connection in connections { connection.close(code: 0, reason: "done") }
    for endpoint in endpoints { await endpoint.close() }
  }

  private static func bindPinned() async throws -> NetEndpointHandle {
    try await netBindEndpoint(
      config: NetEndpointConfig(
        secretKeyHex: netGenerateSecretKeyHex(), relays: [], trustAnchorsPem: [], pathPolicy: "direct-pinned",
        alpns: [mediaAlpn()]))
  }

  private static func loopbackAddress(of addr: NetTunnelAddr) throws -> BenchUDPAddress {
    guard let port = addr.directAddrs.lazy.filter({ !$0.hasPrefix("[") }).compactMap(Self.port).first else {
      throw LoopbackError.connectionFailed
    }

    return try BenchUDPAddress(host: loopbackHost, port: port)
  }

  private static func port(_ address: String) -> UInt16? {
    address.split(separator: ":").last.flatMap { UInt16($0) }
  }
}

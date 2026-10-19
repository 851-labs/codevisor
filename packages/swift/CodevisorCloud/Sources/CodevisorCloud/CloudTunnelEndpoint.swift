import CodevisorClient
import CodevisorNet
import CryptoKit
import Foundation

public struct CloudTunnelInfo: Codable, Equatable, Sendable {
  public var endpointId: String
  public var relayUrl: String?
  public var directAddrs: [String]

  public init(endpointId: String, relayUrl: String? = nil, directAddrs: [String] = []) {
    self.endpointId = endpointId
    self.relayUrl = relayUrl
    self.directAddrs = directAddrs
  }
}

public struct CloudTunnelConfig: Equatable, Sendable {
  public struct Relay: Codable, Equatable, Sendable {
    public var url: String
    public var quicPort: Int?

    public init(url: String, quicPort: Int? = nil) {
      self.url = url
      self.quicPort = quicPort
    }
  }

  public var relays: [Relay]
  public var enabled: Bool

  public init(relays: [Relay], enabled: Bool) {
    self.relays = relays
    self.enabled = enabled
  }
}

enum CloudTunnelIdentity {
  private static let label = Data("codevisor-tunnel-ed25519-v1".utf8)

  static func secretKeyHex(for identity: CloudAppDeviceIdentity) -> String {
    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: identity.secretKey),
      info: label,
      outputByteCount: 32
    )
    return derived.withUnsafeBytes { bytes in
      bytes.map { String(format: "%02x", $0) }.joined()
    }
  }

  static func endpointId(for identity: CloudAppDeviceIdentity) -> String? {
    try? netEndpointIdForSecretKey(secretKeyHex: secretKeyHex(for: identity))
  }
}

public actor CloudTunnelEndpoint {
  public static let channelsALPN = "codevisor/channels/1"

  private let credentialStore: any CloudCredentialStore
  private let trustAnchorsPem: [String]
  private let bindEndpoint: @Sendable (NetEndpointConfig) async throws -> NetEndpointHandle
  private var config: CloudTunnelConfig?
  private var binding: Task<NetEndpointHandle?, Never>?
  private var generation: UInt64 = 0
  private var configWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private let firstConfigWait: Duration
  private var allowsDirectPaths = true

  public init(
    credentialStore: any CloudCredentialStore,
    trustAnchorsPem: [String] = CloudTunnelEndpoint.environmentTrustAnchors(),
    bindEndpoint: @escaping @Sendable (NetEndpointConfig) async throws -> NetEndpointHandle = {
      try await netBindEndpoint(config: $0)
    },
    firstConfigWait: Duration = .seconds(5)
  ) {
    self.credentialStore = credentialStore
    self.bindEndpoint = bindEndpoint
    self.trustAnchorsPem = trustAnchorsPem
    self.firstConfigWait = firstConfigWait
  }

  public static func environmentTrustAnchors(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String] {
    if let pem = environment["CODEVISOR_NET_CA_PEM"], !pem.isEmpty { return [pem] }
    if let path = environment["CODEVISOR_NET_CA_FILE"], !path.isEmpty,
      let pem = try? String(contentsOfFile: path, encoding: .utf8)
    {
      return [pem]
    }
    return []
  }

  public func configure(_ newConfig: CloudTunnelConfig) async {
    guard newConfig != config else { return }
    config = newConfig
    replaceBinding(with: newConfig.enabled ? newConfig : nil)
    let waiters = configWaiters.values
    configWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  public func endpoint() async -> NetEndpointHandle? {
    if config == nil { await waitForFirstConfig() }
    let attempt = binding
    if let handle = await attempt?.value { return handle }
    guard binding == attempt else { return await binding?.value }
    guard let config, config.enabled else { return nil }
    replaceBinding(with: config)
    return await binding?.value
  }

  public func rebuild() {
    guard let config, config.enabled else { return }
    Log.cloud.notice("Rebuilding the tunnel endpoint")
    replaceBinding(with: config)
  }

  public func setAllowsDirectPaths(_ allowed: Bool) {
    guard allowed != allowsDirectPaths else { return }
    allowsDirectPaths = allowed
    guard let config, config.enabled else { return }
    Log.cloud.notice("Rebinding the tunnel endpoint with direct paths \(allowed ? "allowed" : "off", privacy: .public)")
    replaceBinding(with: config)
  }

  public func networkChanged() async {
    guard let handle = await binding?.value else { return }
    await handle.networkChange()
  }

  private func waitForFirstConfig() async {
    let id = UUID()
    let wait = firstConfigWait
    let timeout = Task { [weak self] in
      try? await Task.sleep(for: wait)
      await self?.resumeWaiter(id)
    }
    await withCheckedContinuation { continuation in
      configWaiters[id] = continuation
    }
    timeout.cancel()
  }

  private func resumeWaiter(_ id: UUID) {
    configWaiters.removeValue(forKey: id)?.resume()
  }

  public func shutdown() async {
    config = nil
    replaceBinding(with: nil)
    _ = await binding?.value
  }

  private func replaceBinding(with config: CloudTunnelConfig?) {
    generation &+= 1
    let requestGeneration = generation
    let previous = binding
    let endpointConfig = config.flatMap(endpointConfig(for:))
    let bindEndpoint = bindEndpoint
    binding = Task {
      if let handle = await previous?.value { await handle.close() }
      guard generation == requestGeneration, let endpointConfig else { return nil }
      do {
        let handle = try await bindEndpoint(endpointConfig)
        Log.cloud.notice("Tunnel endpoint up as \(handle.endpointId(), privacy: .public)")
        return handle
      } catch {
        Log.cloud.error("Tunnel endpoint failed to bind: \(String(describing: error), privacy: .public)")
        return nil
      }
    }
  }

  private func endpointConfig(for config: CloudTunnelConfig) -> NetEndpointConfig? {
    let secretKeyHex: String
    do {
      secretKeyHex = CloudTunnelIdentity.secretKeyHex(for: try credentialStore.ensureAppDeviceIdentity())
    } catch {
      Log.cloud.error("Tunnel unavailable: no device identity (\(String(describing: error), privacy: .public))")
      return nil
    }
    return NetEndpointConfig(
      secretKeyHex: secretKeyHex,
      relays: config.relays.map { NetRelay(url: $0.url, quicPort: $0.quicPort.map { UInt16(clamping: $0) }) },
      trustAnchorsPem: trustAnchorsPem,
      pathPolicy: allowsDirectPaths ? "auto" : "relay-only",
      alpns: [Self.channelsALPN]
    )
  }

  public func openMediaRoute(to address: CloudTunnelInfo, flowId: UInt32 = 1) async -> CloudTunnelMediaRoute? {
    guard let handle = await endpoint() else { return nil }
    let addr = NetTunnelAddr(
      endpointId: address.endpointId, relayUrl: address.relayUrl, directAddrs: address.directAddrs)
    do {
      let connection = try await handle.connect(addr: addr, alpn: CloudTunnelMediaRoute.mediaALPN, cancel: nil)
      let flow = try await connection.bindMedia(flowId: flowId)
      return CloudTunnelMediaRoute(
        endpointId: handle.endpointId(), flowId: flowId, connection: connection, flow: flow)
    } catch {
      Log.cloud.notice("Tunnel media route failed: \(String(describing: error), privacy: .public)")
      return nil
    }
  }
}

public final class CloudTunnelMediaRoute: Sendable {
  public static let mediaALPN = "codevisor/media/1"

  public let endpointId: String
  public let flowId: UInt32
  public let localPort: UInt16
  private let connection: NetConnectionHandle
  private let flow: NetMediaFlowHandle

  init(endpointId: String, flowId: UInt32, connection: NetConnectionHandle, flow: NetMediaFlowHandle) {
    self.endpointId = endpointId
    self.flowId = flowId
    self.connection = connection
    self.flow = flow
    localPort = flow.localPort()
  }

  public var maxPayload: Int? { connection.maxMediaPayload().map(Int.init) }

  public func close() {
    flow.close()
    connection.close(code: 0, reason: "media route closed")
  }
}

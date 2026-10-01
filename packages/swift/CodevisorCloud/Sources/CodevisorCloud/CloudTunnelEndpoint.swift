import CodevisorClient
import CodevisorNet
import CryptoKit
import Foundation

/// How to reach a machine's tunnel endpoint, from machine presence
/// (docs/plans/codevisor-tunnel.md).
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

/// The instance's relay map and rollout switch, from the hub's welcome.
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

/// The app's tunnel identity. Derived from the device's X25519 secret with
/// HKDF and a dedicated label, so it is stable per install, needs no extra
/// Keychain item, and rotates exactly when the device identity does.
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

/// The app's single tunnel endpoint. Bound while the hub reports the tunnel
/// enabled, rebound when the relay map changes, closed on sign-out. Machines
/// are dialed by key; the endpoint picks direct or relayed paths itself.
public actor CloudTunnelEndpoint {
  public static let channelsALPN = "codevisor/channels/1"

  private let credentialStore: any CloudCredentialStore
  private let trustAnchorsPem: [String]
  private let bindEndpoint: @Sendable (NetEndpointConfig) async throws -> NetEndpointHandle
  private var config: CloudTunnelConfig?
  private var binding: Task<NetEndpointHandle?, Never>?
  private var generation: UInt64 = 0
  /// Callers that asked for the endpoint before the first hub welcome
  /// configured it; resumed by `configure` or their bounded wait.
  private var configWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private let firstConfigWait: Duration

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

  /// Extra trust anchors for local development relays: the dev CA that
  /// `bun run dev` hands every process (production passes none).
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

  /// Applies a welcome's tunnel config. Idempotent for an unchanged config.
  public func configure(_ newConfig: CloudTunnelConfig) async {
    guard newConfig != config else { return }
    generation &+= 1
    let requestGeneration = generation
    config = newConfig
    defer {
      let waiters = configWaiters.values
      configWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
    await closeEndpoint()
    guard generation == requestGeneration else { return }
    guard newConfig.enabled else { return }
    let secretKeyHex: String
    do {
      secretKeyHex = CloudTunnelIdentity.secretKeyHex(for: try credentialStore.ensureAppDeviceIdentity())
    } catch {
      Log.cloud.error("Tunnel unavailable: no device identity (\(String(describing: error), privacy: .public))")
      return
    }
    let endpointConfig = NetEndpointConfig(
      secretKeyHex: secretKeyHex,
      relays: newConfig.relays.map { NetRelay(url: $0.url, quicPort: $0.quicPort.map { UInt16(clamping: $0) }) },
      trustAnchorsPem: trustAnchorsPem,
      pathPolicy: "auto",
      alpns: [Self.channelsALPN]
    )
    let bindEndpoint = bindEndpoint
    binding = Task {
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

  /// The bound endpoint (waiting for an in-flight bind), or nil when the
  /// tunnel is off or failed to start. Before the first hub welcome has
  /// configured the tunnel, waits for it (bounded): machine probes start at
  /// sign-in, racing that welcome, and must not conclude "no tunnel" early.
  public func endpoint() async -> NetEndpointHandle? {
    if config == nil { await waitForFirstConfig() }
    return await binding?.value
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
    generation &+= 1
    config = nil
    await closeEndpoint()
  }

  private func closeEndpoint() async {
    let previous = binding
    binding = nil
    if let handle = await previous?.value { await handle.close() }
  }
}

/// One screen-sharing media route over the tunnel: a `codevisor/media/1`
/// connection to the machine plus a local UDP port bridged to one flow. The
/// viewer's WebRTC dials `localPort`; the machine bridges the same flow to the
/// host's WebRTC socket. Closing drops both.
public final class CloudTunnelMediaRoute: Sendable {
  public static let mediaALPN = "codevisor/media/1"

  /// This app's own endpoint id, which the machine keys the flow by.
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

  /// Largest UDP payload the flow carries right now (nil until measured).
  public var maxPayload: Int? { connection.maxMediaPayload().map(Int.init) }

  public func close() {
    flow.close()
    connection.close(code: 0, reason: "media route closed")
  }
}

extension CloudTunnelEndpoint {
  /// Opens a media route to a machine's tunnel endpoint, or nil when the
  /// tunnel is off or the machine can't be reached over it.
  public func openMediaRoute(to address: CloudTunnelInfo, flowId: UInt32 = 1) async -> CloudTunnelMediaRoute? {
    guard let handle = await endpoint() else { return nil }
    let addr = NetTunnelAddr(
      endpointId: address.endpointId, relayUrl: address.relayUrl, directAddrs: address.directAddrs)
    do {
      let connection = try await handle.connect(addr: addr, alpn: CloudTunnelMediaRoute.mediaALPN)
      let flow = try await connection.bindMedia(flowId: flowId)
      return CloudTunnelMediaRoute(
        endpointId: handle.endpointId(), flowId: flowId, connection: connection, flow: flow)
    } catch {
      Log.cloud.notice("Tunnel media route failed: \(String(describing: error), privacy: .public)")
      return nil
    }
  }
}

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

  static func screenSharingSigner(for identity: CloudAppDeviceIdentity) throws -> ScreenSharingStartSigner {
    guard let seed = Data(hexEncoded: secretKeyHex(for: identity)) else { throw CocoaError(.coderInvalidValue) }

    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    return ScreenSharingStartSigner(key: key.publicKey.rawRepresentation.hexEncoded) { try key.signature(for: $0) }
  }
}

public actor CloudTunnelEndpoint {
  public static let channelsALPN = "codevisor/channels/1"
  public static let screenALPN = mediaAlpn()

  private enum Binding: Equatable {
    case cloud(CloudTunnelConfig)
    case directOnly
  }

  private let credentialStore: any CloudCredentialStore
  private let trustAnchorsPem: [String]
  private let bindEndpoint: @Sendable (NetEndpointConfig) async throws -> NetEndpointHandle
  private var config: CloudTunnelConfig?
  private var binding: Task<NetEndpointHandle?, Never>?
  private var generation: UInt64 = 0
  private var configWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private let firstConfigWait: Duration
  private let sleep: @Sendable (Duration) async -> Void
  private var firstConfigWaitExpired = false
  private var allowsDirectPaths = false
  private var screenSharingBindsWithoutCloud = false

  public init(
    credentialStore: any CloudCredentialStore,
    trustAnchorsPem: [String] = CloudTunnelEndpoint.environmentTrustAnchors(),
    bindEndpoint: @escaping @Sendable (NetEndpointConfig) async throws -> NetEndpointHandle = {
      try await netBindEndpoint(config: $0)
    },
    firstConfigWait: Duration = .seconds(5),
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.credentialStore = credentialStore
    self.bindEndpoint = bindEndpoint
    self.trustAnchorsPem = trustAnchorsPem
    self.firstConfigWait = firstConfigWait
    self.sleep = sleep
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
    let previous = desiredBinding
    config = newConfig
    if desiredBinding != .directOnly || previous != .directOnly { replaceBinding(with: desiredBinding) }
    let waiters = configWaiters.values
    configWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  public func endpoint() async -> NetEndpointHandle? {
    if config == nil { await waitForFirstConfig() }
    guard config?.enabled == true else { return nil }
    let handle = await currentEndpoint()
    return config?.enabled == true ? handle : nil
  }

  public nonisolated func screenSharingSigner() throws -> ScreenSharingStartSigner {
    try CloudTunnelIdentity.screenSharingSigner(for: try credentialStore.ensureAppDeviceIdentity())
  }

  public func screenSharingEndpoint() async -> NetEndpointHandle? {
    if config == nil { await waitForFirstConfig() }
    screenSharingBindsWithoutCloud = true
    return await currentEndpoint()
  }

  private var desiredBinding: Binding? {
    if let config, config.enabled { return .cloud(config) }
    return screenSharingBindsWithoutCloud ? .directOnly : nil
  }

  private func currentEndpoint() async -> NetEndpointHandle? {
    let attempt = binding
    let handle = await attempt?.value
    guard binding == attempt else { return await binding?.value }
    if let handle { return handle }
    guard let desired = desiredBinding else { return nil }
    replaceBinding(with: desired)
    return await binding?.value
  }

  public func rebuild() {
    guard let desired = desiredBinding else { return }
    Log.cloud.notice("Rebuilding the tunnel endpoint")
    replaceBinding(with: desired)
  }

  public func setAllowsDirectPaths(_ allowed: Bool) {
    guard allowed != allowsDirectPaths else { return }
    allowsDirectPaths = allowed
    guard let config, config.enabled else { return }
    Log.cloud.notice("Rebinding the tunnel endpoint with direct paths \(allowed ? "allowed" : "off", privacy: .public)")
    replaceBinding(with: .cloud(config))
  }

  public func networkChanged() async {
    guard let handle = await binding?.value else { return }
    await handle.networkChange()
  }

  private func waitForFirstConfig() async {
    guard !firstConfigWaitExpired else { return }

    let id = UUID()
    let wait = firstConfigWait
    let sleep = sleep
    let timeout = Task { [weak self] in
      await sleep(wait)
      guard !Task.isCancelled else { return }

      await self?.firstConfigWaitTimedOut(id)
    }
    await withCheckedContinuation { continuation in
      configWaiters[id] = continuation
    }
    timeout.cancel()
  }

  private func firstConfigWaitTimedOut(_ id: UUID) {
    if config == nil { firstConfigWaitExpired = true }
    configWaiters.removeValue(forKey: id)?.resume()
  }

  public func shutdown() async {
    config = nil
    firstConfigWaitExpired = false
    screenSharingBindsWithoutCloud = false
    replaceBinding(with: nil)
    _ = await binding?.value
  }

  private func replaceBinding(with desired: Binding?) {
    generation &+= 1
    let requestGeneration = generation
    let previous = binding
    let endpointConfig = desired.flatMap(endpointConfig(for:))
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

  private func endpointConfig(for desired: Binding) -> NetEndpointConfig? {
    let secretKeyHex: String
    do {
      secretKeyHex = CloudTunnelIdentity.secretKeyHex(for: try credentialStore.ensureAppDeviceIdentity())
    } catch {
      Log.cloud.error("Tunnel unavailable: no device identity (\(String(describing: error), privacy: .public))")
      return nil
    }
    let alpns = [Self.channelsALPN, Self.screenALPN]
    guard case .cloud(let config) = desired else {
      return NetEndpointConfig(
        secretKeyHex: secretKeyHex, relays: [], trustAnchorsPem: [], pathPolicy: "direct-only", alpns: alpns)
    }
    return NetEndpointConfig(
      secretKeyHex: secretKeyHex,
      relays: config.relays.map { NetRelay(url: $0.url, quicPort: $0.quicPort.map { UInt16(clamping: $0) }) },
      trustAnchorsPem: trustAnchorsPem,
      pathPolicy: allowsDirectPaths ? "auto" : "relay-only",
      alpns: alpns
    )
  }
}

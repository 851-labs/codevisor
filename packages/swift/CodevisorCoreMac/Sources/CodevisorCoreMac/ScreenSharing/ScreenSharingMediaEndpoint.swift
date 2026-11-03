import CodevisorClient
import CodevisorCore
import CodevisorNet
import Foundation

@MainActor
public final class ScreenSharingMediaEndpoint {
  public struct Provider: Sendable {
    public let endpoint: @Sendable () async -> NetEndpointHandle?
    public let requestDirectPaths: @MainActor @Sendable () async -> Void

    public init(
      endpoint: @escaping @Sendable () async -> NetEndpointHandle?,
      requestDirectPaths: @escaping @MainActor @Sendable () async -> Void
    ) {
      self.endpoint = endpoint
      self.requestDirectPaths = requestDirectPaths
    }
  }

  public static let shared = ScreenSharingMediaEndpoint()
  private static let addressWait: UInt32 = 2000
  private var provider: Provider?

  public func configure(_ provider: Provider?) {
    self.provider = provider
  }

  var isAvailable: Bool { provider != nil }

  func ready() async -> NetEndpointHandle? {
    guard let provider else { return nil }

    await provider.requestDirectPaths()
    guard let handle = await provider.endpoint() else { return nil }

    let addr = handle.addr()
    if addr.relayUrl == nil, addr.directAddrs.isEmpty { try? await handle.online(timeoutMs: Self.addressWait) }
    return handle
  }

  nonisolated static func address(of handle: NetEndpointHandle) -> ServerScreenSharingMediaAddress {
    let addr = handle.addr()
    return .init(endpointId: addr.endpointId, relayUrl: addr.relayUrl, directAddrs: addr.directAddrs)
  }

  nonisolated static func tunnelAddress(_ address: ServerScreenSharingMediaAddress) -> NetTunnelAddr {
    NetTunnelAddr(endpointId: address.endpointId, relayUrl: address.relayUrl, directAddrs: address.directAddrs)
  }
}

extension ScreenSharingMediaEndpoint.Provider {
  @MainActor
  static func live(environment: AppEnvironment) -> Self {
    let tunnel = environment.cloud.directPaths.tunnel
    return Self(
      endpoint: { await tunnel.screenSharingEndpoint() },
      requestDirectPaths: { [weak environment] in
        guard let environment, environment.localNetworkAccess != .requested else { return }

        environment.setLocalNetworkAccess(.requested)
        await tunnel.setAllowsDirectPaths(true)
      })
  }
}

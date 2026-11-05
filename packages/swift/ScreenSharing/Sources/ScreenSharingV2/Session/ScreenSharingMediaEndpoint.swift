import CodevisorClient
import CodevisorNet
import Foundation

@MainActor
public final class ScreenSharingMediaEndpoint {
  public typealias Provider = @MainActor @Sendable () async -> NetEndpointHandle?

  public static let shared = ScreenSharingMediaEndpoint()
  private static let addressWait: UInt32 = 2000
  private var provider: Provider?
  var viewerHandle: NetEndpointHandle?

  public init() {}

  public func configure(_ provider: Provider?) {
    self.provider = provider
  }

  public var isAvailable: Bool { provider != nil }

  public func ready() async -> NetEndpointHandle? {
    guard let provider else { return nil }

    guard let handle = await provider() else { return nil }

    let addr = handle.addr()
    if addr.relayUrl == nil, addr.directAddrs.isEmpty { try? await handle.online(timeoutMs: Self.addressWait) }
    return handle
  }

  public nonisolated static func address(of handle: NetEndpointHandle) -> ServerScreenSharingMediaAddress {
    let addr = handle.addr()
    return .init(endpointId: addr.endpointId, relayUrl: addr.relayUrl, directAddrs: addr.directAddrs)
  }

  public nonisolated static func tunnelAddress(_ address: ServerScreenSharingMediaAddress) -> NetTunnelAddr {
    NetTunnelAddr(endpointId: address.endpointId, relayUrl: address.relayUrl, directAddrs: address.directAddrs)
  }
}

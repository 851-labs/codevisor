public enum CloudTunnelRoute: Equatable, Sendable {
  case localNetwork(address: String)
  case tailscale(address: String)
  case internet(address: String)
  case relay(url: String)

  init(remote: String, isRelay: Bool, localSubnets: [CloudAddressRange]) {
    guard !isRelay else {
      self = .relay(url: remote)
      return
    }
    guard let address = CloudTunnelAddress(socketAddress: remote) else {
      self = .internet(address: remote)
      return
    }
    self = Self.direct(address, localSubnets: localSubnets)
  }

  private static func direct(_ address: CloudTunnelAddress, localSubnets: [CloudAddressRange]) -> Self {
    if address.isIn(CloudAddressRange.tailscale) { return .tailscale(address: address.host) }
    if address.isIn(CloudAddressRange.localNetwork + localSubnets) { return .localNetwork(address: address.host) }
    return .internet(address: address.host)
  }
}

import Network

struct CloudTunnelAddress: Equatable {
  let host: String
  let bytes: [UInt8]

  init?(socketAddress: String) {
    self.init(host: Self.unscopedHost(of: socketAddress))
  }

  init?(host: String) {
    if let ipv4 = IPv4Address(host) {
      self.init(ipv4)
    } else if let ipv6 = IPv6Address(host) {
      self.init(ipv6, host: host)
    } else {
      return nil
    }
  }

  func isIn(_ ranges: [CloudAddressRange]) -> Bool {
    ranges.contains { $0.contains(bytes) }
  }

  private init(_ ipv4: IPv4Address) {
    self.init(host: "\(ipv4)", bytes: Array(ipv4.rawValue))
  }

  private init(_ ipv6: IPv6Address, host: String) {
    if let mapped = ipv6.asIPv4 {
      self.init(mapped)
    } else {
      self.init(host: host, bytes: Array(ipv6.rawValue))
    }
  }

  private init(host: String, bytes: [UInt8]) {
    self.host = host
    self.bytes = bytes
  }

  private static func unscopedHost(of socketAddress: String) -> String {
    let host = withoutPort(socketAddress)
    return host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
  }

  private static func withoutPort(_ socketAddress: String) -> String {
    if socketAddress.hasPrefix("["), let close = socketAddress.firstIndex(of: "]") {
      return String(socketAddress[socketAddress.index(after: socketAddress.startIndex)..<close])
    }
    guard let colon = socketAddress.lastIndex(of: ":") else { return socketAddress }
    return String(socketAddress[..<colon])
  }
}

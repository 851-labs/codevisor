struct CloudAddressRange: Equatable, Sendable {
  let prefix: [UInt8]
  let bits: Int

  static let tailscale = ranges(["100.64.0.0/10", "fd7a:115c:a1e0::/48"])

  static let localNetwork = ranges([
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8",
    "fc00::/7", "fe80::/10", "::1/128",
  ])

  init(prefix: [UInt8], bits: Int) {
    self.prefix = prefix
    self.bits = bits
  }

  init?(_ cidr: String) {
    let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, let bits = Int(parts[1]), let address = CloudTunnelAddress(host: parts[0])
    else { return nil }
    self.init(prefix: address.bytes, bits: bits)
  }

  func contains(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == prefix.count, bits <= bytes.count * 8 else { return false }
    let whole = bits / 8
    guard bytes.prefix(whole) == prefix.prefix(whole) else { return false }
    let remainder = bits % 8
    guard remainder > 0 else { return true }
    let mask = UInt8.max << (8 - remainder)
    return bytes[whole] & mask == prefix[whole] & mask
  }

  private static func ranges(_ cidrs: [String]) -> [CloudAddressRange] {
    cidrs.compactMap(CloudAddressRange.init)
  }
}

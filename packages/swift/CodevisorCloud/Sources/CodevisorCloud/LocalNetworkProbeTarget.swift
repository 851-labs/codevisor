enum LocalNetworkProbeTarget {
  private static let prefixLengths = 8...29
  private static let linkLocalPrefix: UInt32 = 0xA9FE_0000
  private static let linkLocalMask: UInt32 = 0xFFFF_0000

  static func address(in networks: [LocalIPv4Network]) -> String? {
    networks
      .sorted { ethernetFirst($0) < ethernetFirst($1) }
      .lazy
      .compactMap(neighbor)
      .first
      .map(dotted)
  }

  private static func ethernetFirst(_ network: LocalIPv4Network) -> Int {
    network.interfaceName.hasPrefix("en") ? 0 : 1
  }

  private static func neighbor(of network: LocalIPv4Network) -> UInt32? {
    guard prefixLengths.contains(network.prefixLength), !isLinkLocal(network.address) else { return nil }

    let hostMask = UInt32.max >> UInt32(network.prefixLength)
    let first = (network.address & ~hostMask) + 2
    let last = (network.address | hostMask) - 2
    return [network.address &+ 1, network.address &- 1].first { (first...last).contains($0) }
  }

  private static func isLinkLocal(_ address: UInt32) -> Bool {
    address & linkLocalMask == linkLocalPrefix
  }

  private static func dotted(_ address: UInt32) -> String {
    [24, 16, 8, 0].map { String((address >> UInt32($0)) & 0xFF) }.joined(separator: ".")
  }
}

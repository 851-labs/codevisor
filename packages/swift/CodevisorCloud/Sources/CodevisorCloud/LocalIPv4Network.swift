import Darwin

struct LocalIPv4Network: Equatable, Sendable {
  let interfaceName: String
  let address: UInt32
  let prefixLength: Int

  static func current() -> [LocalIPv4Network] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(list) }
    return sequence(first: first) { $0.pointee.ifa_next }.compactMap { network(of: $0.pointee) }
  }

  private static func network(of interface: ifaddrs) -> LocalIPv4Network? {
    guard isBroadcastLAN(interface.ifa_flags),
      let address = ipv4Value(of: interface.ifa_addr),
      let mask = ipv4Value(of: interface.ifa_netmask)
    else { return nil }
    return LocalIPv4Network(
      interfaceName: String(cString: interface.ifa_name),
      address: address,
      prefixLength: mask.nonzeroBitCount
    )
  }

  private static func isBroadcastLAN(_ flags: UInt32) -> Bool {
    let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
    let excluded = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
    return flags & required == required && flags & excluded == 0
  }

  private static func ipv4Value(of socket: UnsafeMutablePointer<sockaddr>?) -> UInt32? {
    guard let socket, socket.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
    return socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
      UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
    }
  }
}

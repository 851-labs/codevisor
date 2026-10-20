import Darwin

enum CloudLocalInterfaces {
  static func subnets() -> [CloudAddressRange] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(list) }
    return sequence(first: first) { $0.pointee.ifa_next }.compactMap { subnet(of: $0.pointee) }
  }

  private static func subnet(of interface: ifaddrs) -> CloudAddressRange? {
    guard let family = interface.ifa_addr?.pointee.sa_family,
      let address = bytes(of: interface.ifa_addr, family: family),
      let mask = bytes(of: interface.ifa_netmask, family: family)
    else { return nil }
    return CloudAddressRange(prefix: address, bits: mask.reduce(0) { $0 + $1.nonzeroBitCount })
  }

  private static func bytes(of socket: UnsafeMutablePointer<sockaddr>?, family: sa_family_t) -> [UInt8]? {
    guard let socket else { return nil }
    switch Int32(family) {
    case AF_INET:
      return socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        withUnsafeBytes(of: $0.pointee.sin_addr, Array.init)
      }
    case AF_INET6:
      return socket.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
        withUnsafeBytes(of: $0.pointee.sin6_addr, Array.init)
      }
    default:
      return nil
    }
  }
}

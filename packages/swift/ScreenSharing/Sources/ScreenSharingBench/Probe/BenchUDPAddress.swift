import Darwin

public struct BenchUDPAddress: Sendable, Equatable, CustomStringConvertible {
  public let port: UInt16
  let networkOrderIPv4: in_addr_t

  public init(host: String, port: UInt16) throws {
    var address = in_addr()
    guard inet_pton(AF_INET, host, &address) == 1 else { throw BenchSocketError.invalidAddress(host) }

    self.init(networkOrderIPv4: address.s_addr, port: port)
  }

  init(_ socketAddress: sockaddr_in) {
    self.init(networkOrderIPv4: socketAddress.sin_addr.s_addr, port: UInt16(bigEndian: socketAddress.sin_port))
  }

  private init(networkOrderIPv4: in_addr_t, port: UInt16) {
    self.networkOrderIPv4 = networkOrderIPv4
    self.port = port
  }

  public var description: String {
    "\(host):\(port)"
  }

  public var host: String {
    var address = in_addr(s_addr: networkOrderIPv4)
    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &address, &text, socklen_t(text.count))
    return String(decoding: text.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
  }

  var socketAddress: sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: networkOrderIPv4)
    return address
  }
}

public enum BenchSocketError: Error, Equatable {
  case invalidAddress(String)
  case system(call: String, errno: Int32)
}

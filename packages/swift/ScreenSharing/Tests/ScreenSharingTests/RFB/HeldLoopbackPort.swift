import Foundation

final class HeldLoopbackPort {
  let port: UInt16
  private let descriptors: [Int32]

  init() throws {
    var opened: [Int32] = []
    var held = false
    defer { if !held { opened.forEach { _ = Darwin.close($0) } } }

    let listener = try Self.check(socket(AF_INET, SOCK_STREAM, 0), "socket")
    opened.append(listener)
    _ = try Self.check(Self.withLoopback(port: 0) { bind(listener, $0, $1) }, "bind")
    _ = try Self.check(listen(listener, 1), "listen")
    let client = try Self.check(socket(AF_INET, SOCK_STREAM, 0), "socket")
    opened.append(client)
    let listenerPort = try Self.localPort(of: listener)
    _ = try Self.check(Self.withLoopback(port: listenerPort) { connect(client, $0, $1) }, "connect")
    opened.append(try Self.check(accept(listener, nil, nil), "accept"))

    port = try Self.localPort(of: client)
    descriptors = opened
    held = true
  }

  func close() { descriptors.forEach { _ = Darwin.close($0) } }

  private struct SocketCallFailed: Error, CustomStringConvertible {
    let description: String
  }

  private static func check(_ result: Int32, _ call: String) throws -> Int32 {
    guard result >= 0 else {
      throw SocketCallFailed(description: "\(call) failed: \(String(cString: strerror(errno)))")
    }

    return result
  }

  private static func withLoopback(port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
  }

  private static func localPort(of descriptor: Int32) throws -> UInt16 {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = try check(
      withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
      }, "getsockname")
    return UInt16(bigEndian: address.sin_port)
  }
}

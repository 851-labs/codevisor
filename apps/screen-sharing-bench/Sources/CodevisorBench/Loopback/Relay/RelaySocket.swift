import Darwin
import ScreenSharingBench

final class RelaySocket: Sendable {
  struct Datagram {
    let bytes: [UInt8]
    let sender: BenchUDPAddress
  }

  private static let maximumDatagram = 65_536
  private static let bufferBytes: Int32 = 4 << 20

  let descriptor: Int32
  let port: UInt16

  init() throws {
    let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard descriptor >= 0 else { throw RelayError.system(call: "socket", errno: errno) }

    do {
      try Self.configure(descriptor)
      port = try Self.bindAnyPort(descriptor)
      self.descriptor = descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  func receive() -> Datagram? {
    var sender = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bytes = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.maximumDatagram) { buffer -> [UInt8]? in
      let count = withUnsafeMutablePointer(to: &sender) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          recvfrom(descriptor, buffer.baseAddress, buffer.count, 0, $0, &length)
        }
      }
      return count >= 0 ? Array(buffer.prefix(count)) : nil
    }
    return bytes.map { Datagram(bytes: $0, sender: BenchUDPAddress(sender)) }
  }

  @discardableResult
  func send(_ bytes: [UInt8], to address: BenchUDPAddress) -> Bool {
    var target = address.socketAddress
    let sent = bytes.withUnsafeBytes { buffer in
      withUnsafePointer(to: &target) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(descriptor, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
    return sent == bytes.count
  }

  func close() {
    Darwin.close(descriptor)
  }

  private static func configure(_ descriptor: Int32) throws {
    guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
      throw RelayError.system(call: "fcntl", errno: errno)
    }
    for option in [SO_RCVBUF, SO_SNDBUF] {
      var bytes = bufferBytes
      guard setsockopt(descriptor, SOL_SOCKET, option, &bytes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw RelayError.system(call: "setsockopt", errno: errno)
      }
    }
  }

  private static func bindAnyPort(_ descriptor: Int32) throws -> UInt16 {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: INADDR_ANY)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0
      }
    }
    guard bound else { throw RelayError.system(call: "bind", errno: errno) }

    return UInt16(bigEndian: address.sin_port)
  }
}

enum RelayError: Error, Equatable {
  case system(call: String, errno: Int32)
  case noHostCandidate
}

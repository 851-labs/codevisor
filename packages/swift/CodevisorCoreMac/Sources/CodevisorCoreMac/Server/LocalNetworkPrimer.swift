import Darwin
import Foundation

enum LocalNetworkPrimer {
  private static let multicastDNSGroup = "224.0.0.251"
  private static let multicastDNSPort: UInt16 = 5353
  private static let emptyQuery = [UInt8](repeating: 0, count: 12)

  static func prime() -> Bool {
    let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }

    var destination = sockaddr_in()
    destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    destination.sin_family = sa_family_t(AF_INET)
    destination.sin_port = multicastDNSPort.bigEndian
    inet_pton(AF_INET, multicastDNSGroup, &destination.sin_addr)
    let sent = withUnsafePointer(to: &destination) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        sendto(descriptor, emptyQuery, emptyQuery.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return sent == emptyQuery.count
  }
}

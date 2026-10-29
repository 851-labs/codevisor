import Darwin

enum SignalingSocket {
  static let defaultPort: UInt16 = 47_593

  static func listen(port: UInt16) throws -> Int32 {
    let descriptor = try stream()
    var reuse: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = socketAddress(port: port, ipv4: in_addr(s_addr: INADDR_ANY))
    let bound = withSocketAddress(&address) { Darwin.bind(descriptor, $0, $1) }
    guard bound == 0, Darwin.listen(descriptor, 1) == 0 else { throw failure("bind/listen", closing: descriptor) }

    return descriptor
  }

  static func accept(on listener: Int32, timeout: Duration) throws -> SignalingConnection {
    try waitReadable(listener, timeout: timeout, what: "waiting for a connection")
    var peer = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let descriptor = withUnsafeMutablePointer(to: &peer) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listener, $0, &length) }
    }
    guard descriptor >= 0 else { throw SignalingError.system(call: "accept", errno: errno) }

    return SignalingConnection(descriptor: descriptor, peerIPv4: text(peer.sin_addr))
  }

  static func connect(host: String, port: UInt16) throws -> SignalingConnection {
    var ipv4 = in_addr()
    guard inet_pton(AF_INET, host, &ipv4) == 1 else { throw SignalingError.invalidAddress(host) }

    let descriptor = try stream()
    var address = socketAddress(port: port, ipv4: ipv4)
    let connected = withSocketAddress(&address) { Darwin.connect(descriptor, $0, $1) }
    guard connected == 0 else { throw failure("connect", closing: descriptor) }

    return SignalingConnection(descriptor: descriptor, peerIPv4: host)
  }

  static func connect(
    host: String, port: UInt16, until deadline: ContinuousClock.Instant, retry: Duration
  )
    async throws -> SignalingConnection
  {
    while true {
      do {
        return try connect(host: host, port: port)
      } catch {
        guard ContinuousClock.now + retry < deadline else { throw error }

        try await Task.sleep(for: retry)
      }
    }
  }

  private static func stream() throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard descriptor >= 0 else { throw SignalingError.system(call: "socket", errno: errno) }

    var noDelay: Int32 = 1
    setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
    return descriptor
  }

  private static func waitReadable(_ descriptor: Int32, timeout: Duration, what: String) throws {
    var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    let milliseconds = Int32(timeout.components.seconds * 1_000)
    let ready = poll(&poller, 1, milliseconds)
    guard ready >= 0 else { throw SignalingError.system(call: "poll", errno: errno) }
    guard ready > 0 else { throw SignalingError.timedOut(what) }
  }

  private static func socketAddress(port: UInt16, ipv4: in_addr) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = ipv4
    return address
  }

  private static func withSocketAddress<Result>(
    _ address: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
  ) -> Result {
    withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
  }

  private static func failure(_ call: String, closing descriptor: Int32) -> SignalingError {
    let error = SignalingError.system(call: call, errno: errno)
    close(descriptor)
    return error
  }

  private static func text(_ address: in_addr) -> String {
    var address = address
    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &address, &text, socklen_t(text.count))
    return String(decoding: text.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
  }
}

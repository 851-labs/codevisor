import Darwin

final class BenchUDPSocket: Sendable {
  private struct Bound {
    let descriptor: Int32
    let port: UInt16
  }

  private struct Received {
    let payloadLength: Int
    let controlLength: Int
    let error: Int32
  }

  private static let maximumDatagram = 512
  private static let controlCapacity = 64
  private static let controlAlignment = 4
  private static let attosecondsPerMicrosecond: Int64 = 1_000_000_000_000

  let port: UInt16
  private let descriptor: Int32
  private let continuousMinusAbsoluteNs = BenchMachClock.continuousMinusAbsoluteNs()

  init(port: UInt16 = 0, receiveTimeout: Duration) throws {
    let bound = try Self.open(port: port, receiveTimeout: receiveTimeout)
    descriptor = bound.descriptor
    self.port = bound.port
  }

  deinit {
    close(descriptor)
  }

  func send(_ bytes: [UInt8], to address: BenchUDPAddress) throws {
    var target = address.socketAddress
    let sent = bytes.withUnsafeBytes { buffer in
      withUnsafePointer(to: &target) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
          sendto(descriptor, buffer.baseAddress, buffer.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
    guard sent == bytes.count else { throw BenchSocketError.system(call: "sendto", errno: errno) }
  }

  func receive() throws -> BenchUDPDatagram? {
    var payload = [UInt8](repeating: 0, count: Self.maximumDatagram)
    var control = [UInt8](repeating: 0, count: Self.controlCapacity)
    var sender = sockaddr_in()
    let received = receiveMessage(into: &payload, control: &control, sender: &sender)
    guard received.payloadLength >= 0 else { return try Self.timedOut(received.error) }

    let kernelTicks = Self.monotonicTimestamp(in: Array(control.prefix(received.controlLength)))
    return BenchUDPDatagram(
      bytes: Array(payload.prefix(received.payloadLength)), sender: BenchUDPAddress(sender),
      receivedNs: kernelTicks.map(continuousNs(fromAbsoluteTicks:)) ?? BenchMachClock.nowNs())
  }

  private func continuousNs(fromAbsoluteTicks ticks: UInt64) -> Int64 {
    BenchMachClock.nanoseconds(fromTicks: ticks) + continuousMinusAbsoluteNs
  }

  private func receiveMessage(
    into payload: inout [UInt8], control: inout [UInt8], sender: inout sockaddr_in
  ) -> Received {
    payload.withUnsafeMutableBytes { payloadBuffer in
      control.withUnsafeMutableBytes { controlBuffer in
        withUnsafeMutablePointer(to: &sender) { senderPointer in
          var vector = iovec(iov_base: payloadBuffer.baseAddress, iov_len: payloadBuffer.count)
          return withUnsafeMutablePointer(to: &vector) { vectorPointer in
            var message = msghdr(
              msg_name: UnsafeMutableRawPointer(senderPointer), msg_namelen: socklen_t(MemoryLayout<sockaddr_in>.size),
              msg_iov: vectorPointer, msg_iovlen: 1, msg_control: controlBuffer.baseAddress,
              msg_controllen: socklen_t(controlBuffer.count), msg_flags: 0)
            let length = recvmsg(descriptor, &message, 0)
            return Received(payloadLength: length, controlLength: Int(message.msg_controllen), error: errno)
          }
        }
      }
    }
  }

  private static func timedOut(_ error: Int32) throws -> BenchUDPDatagram? {
    guard error == EAGAIN || error == EINTR else { throw BenchSocketError.system(call: "recvmsg", errno: error) }

    return nil
  }

  private static func monotonicTimestamp(in control: [UInt8]) -> UInt64? {
    let headerSize = MemoryLayout<cmsghdr>.size
    var offset = 0
    while offset + headerSize <= control.count {
      let header = control.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self) }
      let length = Int(header.cmsg_len)
      guard length >= headerSize, offset + length <= control.count else { return nil }

      if isMonotonicTimestamp(header) {
        return control.withUnsafeBytes {
          $0.loadUnaligned(fromByteOffset: offset + aligned(headerSize), as: UInt64.self)
        }
      }
      offset += aligned(length)
    }
    return nil
  }

  private static func isMonotonicTimestamp(_ header: cmsghdr) -> Bool {
    header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_TIMESTAMP_MONOTONIC
  }

  private static func aligned(_ length: Int) -> Int {
    (length + controlAlignment - 1) & ~(controlAlignment - 1)
  }

  private static func open(port: UInt16, receiveTimeout: Duration) throws -> Bound {
    let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard descriptor >= 0 else { throw BenchSocketError.system(call: "socket", errno: errno) }

    do {
      try setOption(SO_TIMESTAMP_MONOTONIC, to: Int32(1), on: descriptor)
      try setOption(SO_RCVTIMEO, to: timeInterval(receiveTimeout), on: descriptor)
      try bind(descriptor, port: port)
      return Bound(descriptor: descriptor, port: try boundPort(of: descriptor))
    } catch {
      close(descriptor)
      throw error
    }
  }

  private static func setOption<Value: BitwiseCopyable>(_ option: Int32, to value: Value, on descriptor: Int32) throws {
    var value = value
    guard setsockopt(descriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Value>.size)) == 0 else {
      throw BenchSocketError.system(call: "setsockopt", errno: errno)
    }
  }

  private static func timeInterval(_ duration: Duration) -> timeval {
    let (seconds, attoseconds) = duration.components
    return timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / attosecondsPerMicrosecond))
  }

  private static func bind(_ descriptor: Int32, port: UInt16) throws {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_ANY)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else { throw BenchSocketError.system(call: "bind", errno: errno) }
  }

  private static func boundPort(of descriptor: Int32) throws -> UInt16 {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard result == 0 else { throw BenchSocketError.system(call: "getsockname", errno: errno) }

    return UInt16(bigEndian: address.sin_port)
  }
}

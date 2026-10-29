import Darwin
import Foundation
import Synchronization

final class SignalingConnection: Sendable {
  private static let chunkSize = 64 * 1024
  private static let newline = UInt8(ascii: "\n")

  let peerIPv4: String
  private let descriptor: Int32
  private let buffered = Mutex<[UInt8]>([])

  init(descriptor: Int32, peerIPv4: String) {
    self.descriptor = descriptor
    self.peerIPv4 = peerIPv4
  }

  deinit {
    Darwin.close(descriptor)
  }

  func send(_ message: some Encodable) throws {
    let bytes = Array(try JSONEncoder().encode(message)) + [Self.newline]
    let sent = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
    guard sent == bytes.count else { throw SignalingError.system(call: "send", errno: errno) }
  }

  func receive<Message: Decodable>(_ type: Message.Type) throws -> Message {
    guard let line = try readLine() else { throw SignalingError.closed }

    return try JSONDecoder().decode(type, from: Data(line))
  }

  func setReceiveTimeout(until deadline: ContinuousClock.Instant) throws {
    let (seconds, attoseconds) = (deadline - ContinuousClock.now).components
    guard seconds > 0 || attoseconds > 0 else { throw SignalingError.timedOut("waiting for the other Mac") }

    var interval = timeval(tv_sec: Int(seconds), tv_usec: Int32(max(attoseconds / 1_000_000_000_000, 1)))
    guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size)) == 0
    else { throw SignalingError.system(call: "setsockopt", errno: errno) }
  }

  var isClosedByPeer: Bool {
    var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    guard poll(&poller, 1, 0) > 0 else { return false }

    var byte: UInt8 = 0
    return recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT) <= 0
  }

  func waitForClose() {
    while (try? readChunk()) != nil {}
  }

  func shutDown() {
    Darwin.shutdown(descriptor, SHUT_RDWR)
  }

  private func readLine() throws -> [UInt8]? {
    while true {
      if let line = takeLine() { return line }
      guard let chunk = try readChunk() else { return nil }

      buffered.withLock { $0 += chunk }
    }
  }

  private func takeLine() -> [UInt8]? {
    buffered.withLock { bytes in
      guard let end = bytes.firstIndex(of: Self.newline) else { return nil }

      let line = Array(bytes[..<end])
      bytes.removeSubrange(...end)
      return line
    }
  }

  private func readChunk() throws -> [UInt8]? {
    var chunk = [UInt8](repeating: 0, count: Self.chunkSize)
    let count = chunk.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
    guard count >= 0 else { throw Self.receiveError(errno) }

    return count == 0 ? nil : Array(chunk.prefix(count))
  }

  private static func receiveError(_ error: Int32) -> SignalingError {
    guard error == EAGAIN else { return .system(call: "recv", errno: error) }

    return .timedOut("waiting for the other Mac")
  }
}

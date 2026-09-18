import CodevisorClient
import Foundation
import ScreenSharing

/// RFB bytes over the server's VNC socket route: every binary message is a
/// run of bytes from the machine's loopback VNC server, in order. A read hands
/// out at most `maximum` bytes and keeps the rest of the message for the next
/// one; the peer's close surfaces as an empty read.
public final class RFBWebSocketTransport: RFBTransport, @unchecked Sendable {
  private let socket: any ServerWebSocketConnecting
  private let lock = NSLock()
  private var buffered: [UInt8] = []
  private var closed = false

  public init(socket: any ServerWebSocketConnecting) {
    self.socket = socket
  }

  public func read(maximum: Int) async throws -> [UInt8] {
    while true {
      if let bytes = takeBuffered(maximum: max(1, maximum)) { return bytes }
      if isClosed { throw RFBError.connectionClosed }
      let message: ServerWebSocketMessage
      do {
        message = try await socket.receive()
      } catch {
        if isClosed { throw RFBError.connectionClosed }
        if socket.closeCode != .invalid { return [] }
        throw RFBError.transport(error.localizedDescription)
      }
      switch message {
      case .data(let data): append([UInt8](data))
      case .string: throw RFBError.transport("The VNC socket sent text instead of RFB bytes.")
      }
    }
  }

  public func write(_ bytes: [UInt8]) async throws {
    if isClosed { throw RFBError.connectionClosed }
    do {
      try await socket.send(.data(Data(bytes)))
    } catch {
      throw isClosed ? RFBError.connectionClosed : RFBError.transport(error.localizedDescription)
    }
  }

  public func close() {
    lock.lock()
    let first = !closed
    closed = true
    lock.unlock()
    if first { socket.cancel(with: .normalClosure, reason: nil) }
  }

  private var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }

  private func append(_ bytes: [UInt8]) {
    lock.lock()
    buffered.append(contentsOf: bytes)
    lock.unlock()
  }

  private func takeBuffered(maximum: Int) -> [UInt8]? {
    lock.lock()
    defer { lock.unlock() }
    guard !buffered.isEmpty else { return nil }
    let count = min(maximum, buffered.count)
    let bytes = Array(buffered.prefix(count))
    buffered.removeFirst(count)
    return bytes
  }
}

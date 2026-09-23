import CodevisorClient
import Foundation
import ScreenSharing

/// RFB bytes over the server's VNC socket route: every binary message is a
/// run of bytes from the machine's loopback VNC server, in order. A read hands
/// out at most `maximum` bytes and keeps the rest of the message for the next
/// one; the peer's close surfaces as an empty read.
public final class RFBWebSocketTransport: RFBTransport, @unchecked Sendable {
  public var name: String { "WebSocket" }
  private let socket: any ServerWebSocketConnecting
  private let lock = NSLock()
  private var buffered: [UInt8] = []
  /// Bytes of `buffered` already handed out; compacted once it passes half (851-2320).
  private var consumed = 0
  /// Bytes moved by compaction, for the operation-count test.
  private(set) var bytesMoved = 0
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

  /// Hands out the next bytes by moving an offset, not by shifting the rest:
  /// `removeFirst` made reading a 1 MiB message in 64 KiB pieces move ~8 MiB.
  /// The consumed prefix is dropped once it is at least half the buffer, so
  /// every byte is moved at most once on average.
  private func takeBuffered(maximum: Int) -> [UInt8]? {
    lock.lock()
    defer { lock.unlock() }
    let available = buffered.count - consumed
    guard available > 0 else { return nil }
    let count = min(maximum, available)
    let bytes = Array(buffered[consumed..<consumed + count])
    consumed += count
    if consumed == buffered.count {
      buffered.removeAll(keepingCapacity: true)
      consumed = 0
    } else if consumed * 2 >= buffered.count {
      bytesMoved += buffered.count - consumed
      buffered.removeFirst(consumed)
      consumed = 0
    }
    return bytes
  }
}

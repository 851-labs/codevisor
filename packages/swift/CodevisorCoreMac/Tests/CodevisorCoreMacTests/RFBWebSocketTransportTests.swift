import CodevisorClient
import Foundation
import ScreenSharing
import Testing
@testable import CodevisorCoreMac

/// RFB bytes over a scripted WebSocket: message boundaries never leak into
/// reads, the peer's close is an empty read, and closing fails what follows.
struct RFBWebSocketTransportTests {
  final class ScriptedSocket: ServerWebSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [ServerWebSocketMessage]
    private(set) var sent: [Data] = []
    private(set) var cancelled: URLSessionWebSocketTask.CloseCode?
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    var failSend = false

    init(inbound: [ServerWebSocketMessage]) { self.inbound = inbound }

    func send(_ message: ServerWebSocketMessage) async throws {
      if failSend { throw URLError(.networkConnectionLost) }
      guard case .data(let data) = message else { return }
      lock.withLock { sent.append(data) }
    }

    func receive() async throws -> ServerWebSocketMessage {
      let next = lock.withLock { inbound.isEmpty ? nil : inbound.removeFirst() }
      guard let next else { throw URLError(.networkConnectionLost) }
      return next
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
      cancelled = closeCode
    }
  }

  @Test func readsSpanAndSplitMessagesWithoutLosingBytes() async throws {
    let socket = ScriptedSocket(inbound: [.data(Data([1, 2, 3, 4, 5])), .data(Data()), .data(Data([6, 7]))])
    let transport = RFBWebSocketTransport(socket: socket)
    #expect(try await transport.read(maximum: 2) == [1, 2])
    #expect(try await transport.read(maximum: 10) == [3, 4, 5])
    #expect(try await transport.read(maximum: 1) == [6])
    #expect(try await transport.read(maximum: 1) == [7])
    socket.closeCode = .normalClosure
    #expect(try await transport.read(maximum: 8) == [])
  }

  @Test func writesForwardBinaryFramesAndFailuresBecomeTransportErrors() async throws {
    let socket = ScriptedSocket(inbound: [.string("text")])
    let transport = RFBWebSocketTransport(socket: socket)
    try await transport.write([0x52, 0x46, 0x42])
    #expect(socket.sent == [Data([0x52, 0x46, 0x42])])
    await #expect(throws: RFBError.self) { try await transport.read(maximum: 4) }
    socket.failSend = true
    await #expect(throws: RFBError.self) { try await transport.write([1]) }
    await #expect(throws: RFBError.self) { try await transport.read(maximum: 4) }
  }

  @Test func closingIsIdempotentAndFailsLaterReadsAndWrites() async throws {
    let socket = ScriptedSocket(inbound: [.data(Data([9]))])
    let transport = RFBWebSocketTransport(socket: socket)
    transport.close()
    transport.close()
    #expect(socket.cancelled == .normalClosure)
    // Bytes already buffered still drain; then the closed transport fails.
    await #expect(throws: RFBError.connectionClosed) { try await transport.read(maximum: 1) }
    await #expect(throws: RFBError.connectionClosed) { try await transport.write([1]) }
  }

  /// 851-2320: reading a 1 MiB message in 64 KiB pieces moves each byte at
  /// most once (it moved ~8 MiB with `removeFirst`), and the bytes are intact.
  @Test func readingALargeMessageInPiecesMovesEachByteAtMostOnce() async throws {
    let message = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
    let socket = ScriptedSocket(inbound: [.data(Data(message))])
    let transport = RFBWebSocketTransport(socket: socket)
    var received: [UInt8] = []
    while received.count < message.count {
      received += try await transport.read(maximum: 1 << 16)
    }
    #expect(received == message)
    #expect(transport.bytesMoved <= message.count, "moved \(transport.bytesMoved) bytes")
  }
}

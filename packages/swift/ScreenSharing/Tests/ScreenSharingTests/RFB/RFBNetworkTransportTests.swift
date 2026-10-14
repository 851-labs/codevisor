import CodevisorTestSupport
import Foundation
import Network
import Testing
@testable import ScreenSharing

final class LoopbackListener: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.851labs.Codevisor.tests.rfb-listener")
  private let lock = NSLock()
  private var connections: [NWConnection] = []
  private let listener: NWListener
  private let handle: @Sendable (NWConnection) -> Void
  private(set) var port: UInt16 = 0
  let accepted = TestSignal()

  init(handle: @escaping @Sendable (NWConnection) -> Void) async throws {
    self.handle = handle
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
    listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    port = try await withCheckedThrowingContinuation { continuation in
      let once = RFBOnce()
      listener.stateUpdateHandler = { [listener] state in
        switch state {
        case .ready: if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
        case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }

  private func accept(_ connection: NWConnection) {
    lock.withLock { connections.append(connection) }
    connection.start(queue: queue)
    handle(connection)
    accepted.signal()
  }

  func stop() {
    lock.withLock {
      for connection in connections { connection.cancel() }
      connections = []
    }
    listener.cancel()
  }

  func stopAndWaitUntilUnbound() async {
    lock.withLock {
      for connection in connections { connection.cancel() }
      connections = []
    }
    await withCheckedContinuation { continuation in
      let once = RFBOnce()
      listener.stateUpdateHandler = { state in
        if case .cancelled = state, once.claim() { continuation.resume() }
      }
      listener.cancel()
    }
  }

  static func echo(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
      if let data, !data.isEmpty { connection.send(content: data, completion: .idempotent) }
      guard !complete, error == nil else { return }
      echo(connection)
    }
  }

  static func closeOnFirstByte(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
      connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }
  }
}

struct RFBNetworkTransportTests {
  private func readExactly(
    _ count: Int, from transport: RFBNetworkTransport, maximum: Int = 1 << 16
  ) async throws
    -> [UInt8]
  {
    var bytes: [UInt8] = []
    while bytes.count < count {
      let chunk = try await transport.read(maximum: maximum)
      if chunk.isEmpty { break }
      bytes += chunk
    }
    return bytes
  }

  @Test func bytesTravelBothWaysOverTheAssignedPort() async throws {
    let listener = try await LoopbackListener(handle: LoopbackListener.echo)
    defer { listener.stop() }
    #expect(listener.port != 0)
    let transport = try await RFBNetworkTransport.connect(host: "127.0.0.1", port: listener.port)
    defer { transport.close() }
    await listener.accepted.wait()
    try await transport.write([1, 2, 3, 4])
    #expect(try await readExactly(4, from: transport) == [1, 2, 3, 4])
  }

  @Test func aLargeWriteIsReassembledByTheReader() async throws {
    let listener = try await LoopbackListener(handle: LoopbackListener.echo)
    defer { listener.stop() }
    let transport = try await RFBNetworkTransport.connect(host: "127.0.0.1", port: listener.port)
    defer { transport.close() }
    let payload = (0..<(256 * 1024)).map { UInt8($0 % 251) }
    try await transport.write(payload)
    #expect(try await readExactly(payload.count, from: transport) == payload)
  }

  @Test func readsNeverExceedTheRequestedMaximum() async throws {
    let listener = try await LoopbackListener(handle: LoopbackListener.echo)
    defer { listener.stop() }
    let transport = try await RFBNetworkTransport.connect(host: "127.0.0.1", port: listener.port)
    defer { transport.close() }
    let payload = (0..<4096).map { UInt8($0 % 251) }
    try await transport.write(payload)
    var received: [UInt8] = []
    while received.count < payload.count {
      let chunk = try await transport.read(maximum: 100)
      #expect((1...100).contains(chunk.count))
      received += chunk
    }
    #expect(received == payload)
  }

  @Test func aZeroMaximumStillReturnsAByte() async throws {
    let listener = try await LoopbackListener(handle: LoopbackListener.echo)
    defer { listener.stop() }
    let transport = try await RFBNetworkTransport.connect(host: "127.0.0.1", port: listener.port)
    defer { transport.close() }
    try await transport.write([9, 9, 9, 9])
    let chunk = try await transport.read(maximum: 0)
    #expect(!chunk.isEmpty)
    #expect(chunk.allSatisfy { $0 == 9 })
  }

  @Test func aPeerClosingMidReadEndsTheStreamWithNoBytes() async throws {
    let listener = try await LoopbackListener(handle: LoopbackListener.closeOnFirstByte)
    defer { listener.stop() }
    let transport = try await RFBNetworkTransport.connect(host: "127.0.0.1", port: listener.port)
    defer { transport.close() }
    try await transport.write([0])
    #expect(try await transport.read(maximum: 64) == [])
    await #expect(throws: RFBError.self) { _ = try await transport.read(maximum: 64) }
  }

  @Test func theStreamLayerTurnsThatEmptyReadIntoAClosedConnection() async throws {
    let listener = try await LoopbackListener(handle: LoopbackListener.closeOnFirstByte)
    defer { listener.stop() }
    let transport = try await RFBNetworkTransport.connect(host: "127.0.0.1", port: listener.port)
    defer { transport.close() }
    try await transport.write([0])
    await #expect(throws: RFBError.connectionClosed) { _ = try await RFBInputStream(transport: transport).u8() }
  }

  @Test func readsAfterCloseTerminateWithoutData() async throws {
    let listener = try await LoopbackListener(handle: LoopbackListener.echo)
    defer { listener.stop() }
    let transport = try await RFBNetworkTransport.connect(host: "127.0.0.1", port: listener.port)
    transport.close()
    do {
      #expect(try await transport.read(maximum: 64) == [])
    } catch {
      #expect(error is RFBError)
    }
  }

  @Test func aCloseDuringAPendingReadTerminatesIt() async throws {
    let listener = try await LoopbackListener(handle: LoopbackListener.echo)
    defer { listener.stop() }
    let transport = try await RFBNetworkTransport.connect(host: "127.0.0.1", port: listener.port)
    await listener.accepted.wait()
    let reading = Task { try await transport.read(maximum: 64) }
    transport.close()
    do {
      #expect(try await reading.value == [])
    } catch {
      #expect(error is RFBError)
    }
  }

  @Test func writingToAClosedTransportFails() async throws {
    let listener = try await LoopbackListener(handle: LoopbackListener.echo)
    defer { listener.stop() }
    let transport = try await RFBNetworkTransport.connect(host: "127.0.0.1", port: listener.port)
    transport.close()
    await #expect(throws: RFBError.self) { try await transport.write([1, 2, 3]) }
  }

  @Test func cancellingTheReadingTaskDoesNotAbandonTheReceive() async throws {
    let listener = try await LoopbackListener(handle: LoopbackListener.echo)
    defer { listener.stop() }
    let transport = try await RFBNetworkTransport.connect(host: "127.0.0.1", port: listener.port)
    defer { transport.close() }
    await listener.accepted.wait()
    let reading = Task { try await transport.read(maximum: 64) }
    reading.cancel()
    try await transport.write([42])
    #expect(try await reading.value == [42])
  }

  @Test func connectingToAPortNobodyIsListeningOnIsRefused() async throws {
    let listener = try await LoopbackListener(handle: LoopbackListener.echo)
    let port = listener.port
    await listener.stopAndWaitUntilUnbound()
    await #expect(throws: RFBError.transport("The VNC server refused the connection.")) {
      _ = try await RFBNetworkTransport.connect(host: "127.0.0.1", port: port)
    }
  }
}

import CodevisorClient
import CodevisorNet
import Foundation

/// The tunnel as a WebSocket-shaped transport, so `CloudDirectConnection`
/// (hello/welcome, sealed channels, flow control, heartbeats) runs over it
/// unchanged: each "socket" is one QUIC connection to the machine's endpoint
/// carrying one message stream (text = JSON control, binary = envelopes).
/// The machine admits the connection only when the QUIC-authenticated
/// endpoint key and the hello's device key both match its pins or the hub's
/// vouching; the channel crypto then authenticates the machine's pinned key.
struct CloudTunnelWebSocketTransport: ServerWebSocketTransport {
  let endpoint: CloudTunnelEndpoint
  let address: CloudTunnelInfo

  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
    CloudTunnelSocket(endpoint: endpoint, address: address)
  }
}

enum CloudTunnelError: Error {
  case unavailable
  case closed
}

final class CloudTunnelSocket: ServerWebSocketConnecting, @unchecked Sendable {
  private let lock = NSLock()
  private var connection: NetConnectionHandle?
  private var cancelled = false
  private var recordedCloseCode: URLSessionWebSocketTask.CloseCode = .invalid
  /// Dials lazily and opens the connection's one message stream. Set once in
  /// init (after every other property), read-only afterwards.
  private var opened: Task<NetMessageStreamHandle, any Error>!

  init(endpoint: CloudTunnelEndpoint, address: CloudTunnelInfo) {
    let addr = NetTunnelAddr(
      endpointId: address.endpointId,
      relayUrl: address.relayUrl,
      directAddrs: address.directAddrs
    )
    opened = Task { [weak self] in
      guard let handle = await endpoint.endpoint() else { throw CloudTunnelError.unavailable }
      let connection = try await handle.connect(addr: addr, alpn: CloudTunnelEndpoint.channelsALPN)
      guard let self, self.adopt(connection) else {
        connection.close(code: 1000, reason: "cancelled")
        throw CancellationError()
      }
      return try await connection.openMessageStream()
    }
  }

  /// Keeps the dialed connection unless the socket was cancelled meanwhile.
  private func adopt(_ connection: NetConnectionHandle) -> Bool {
    lock.withLock {
      guard !cancelled else { return false }
      self.connection = connection
      return true
    }
  }

  var closeCode: URLSessionWebSocketTask.CloseCode {
    lock.withLock { recordedCloseCode }
  }

  func send(_ message: ServerWebSocketMessage) async throws {
    let stream = try await opened.value
    switch message {
    case let .string(text): try await stream.send(kind: 0, payload: Data(text.utf8))
    case let .data(data): try await stream.send(kind: 1, payload: data)
    }
  }

  func receive() async throws -> ServerWebSocketMessage {
    let stream = try await opened.value
    guard let message = try await stream.recv() else {
      lock.withLock { recordedCloseCode = .normalClosure }
      throw CloudTunnelError.closed
    }
    return message.kind == 0
      ? .string(String(decoding: message.payload, as: UTF8.self))
      : .data(message.payload)
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    let connection = lock.withLock { () -> NetConnectionHandle? in
      cancelled = true
      if recordedCloseCode == .invalid { recordedCloseCode = closeCode }
      return self.connection
    }
    opened.cancel()
    connection?.close(code: UInt32(closeCode.rawValue), reason: "")
  }

  func markUnanswered() {}
}

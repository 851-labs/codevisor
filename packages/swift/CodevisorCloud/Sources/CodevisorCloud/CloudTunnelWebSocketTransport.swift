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
  /// Reads the path of whichever connection this transport dialed last.
  let paths = CloudTunnelPathProbe()

  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
    CloudTunnelSocket(endpoint: endpoint, address: address, paths: paths)
  }
}

/// How a tunnel pipe reaches its machine right now: straight to it, or through one of our
/// relays, and the round trip QUIC measured on that path.
public struct CloudTunnelPath: Equatable, Sendable {
  public var isRelayed: Bool
  /// The relay's URL on a relayed path.
  public var relayURL: String?
  public var roundTripMilliseconds: Int

  public init(isRelayed: Bool, relayURL: String? = nil, roundTripMilliseconds: Int) {
    self.isRelayed = isRelayed
    self.relayURL = relayURL
    self.roundTripMilliseconds = roundTripMilliseconds
  }
}

/// The live connection's path, read on demand (QUIC keeps the RTT current).
final class CloudTunnelPathProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var connection: NetConnectionHandle?

  func adopt(_ connection: NetConnectionHandle) {
    lock.withLock { self.connection = connection }
  }

  func current() -> CloudTunnelPath? {
    guard let connection = lock.withLock({ connection }) else { return nil }
    let paths = connection.paths()
    guard let path = paths.first(where: \.selected) ?? paths.first else { return nil }
    return CloudTunnelPath(
      isRelayed: path.isRelay,
      relayURL: path.isRelay ? path.remote : nil,
      roundTripMilliseconds: Int(path.rttMs.rounded())
    )
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
  /// Stops the dial in Rust when the socket is cancelled mid-handshake. The
  /// generated Swift glue never cancels a Rust future, so cancelling
  /// `opened` alone would leave the handshake running to its timeout — and
  /// the machine waiting on it.
  private let dialCancel = NetCancelToken()
  /// Dials lazily and opens the connection's one message stream. Set once in
  /// init (after every other property), read-only afterwards.
  private var opened: Task<NetMessageStreamHandle, any Error>!

  init(endpoint: CloudTunnelEndpoint, address: CloudTunnelInfo, paths: CloudTunnelPathProbe) {
    let addr = NetTunnelAddr(
      endpointId: address.endpointId,
      relayUrl: address.relayUrl,
      directAddrs: address.directAddrs
    )
    let dialCancel = dialCancel
    opened = Task { [weak self] in
      guard let handle = await endpoint.endpoint() else { throw CloudTunnelError.unavailable }
      try Task.checkCancellation()
      let connection = try await handle.connect(
        addr: addr, alpn: CloudTunnelEndpoint.channelsALPN, cancel: dialCancel)
      guard let self, self.adopt(connection) else {
        connection.close(code: 1000, reason: "cancelled")
        throw CancellationError()
      }
      paths.adopt(connection)
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
    dialCancel.cancel()
    connection?.close(code: UInt32(closeCode.rawValue), reason: "")
  }

  func markUnanswered() {}
}
